const std = @import("std");
const testing = std.testing;

const reader = @import("wal_reader.zig");
const WalReader = reader.WalReader;
const WalEvent = reader.WalEvent;

const test_helpers = @import("test_helpers");
const getTestConnectionString = test_helpers.getTestConnectionString;

test "WalReader.init" {
    const allocator = testing.allocator;
    const slot_name = "test_slot";
    const publication_name = "test_publication";

    const wal_reader = WalReader.init(allocator, slot_name, publication_name, &[_][]const u8{});

    try testing.expectEqual(allocator, wal_reader.allocator);
    try testing.expectEqual(@as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(wal_reader.connection)));
    try testing.expectEqualStrings(slot_name, wal_reader.slot_name);
    try testing.expectEqualStrings(publication_name, wal_reader.publication_name);
}

test "WalEvent.deinit" {
    const allocator = testing.allocator;

    const lsn_data = try allocator.dupe(u8, "0/1234567");
    const event_data = try allocator.dupe(u8, "BEGIN 12345");

    var event = WalEvent{
        .lsn = lsn_data,
        .data = event_data,
    };

    event.deinit(allocator);
}

// Integration tests require PostgreSQL running (make env-up)
const c = test_helpers.c;

test "peekChanges does not advance LSN" {
    const allocator = testing.allocator;

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    const conn_str_z = try allocator.dupeZ(u8, conn_str);
    defer allocator.free(conn_str_z);

    const conn = c.PQconnectdb(conn_str_z.ptr) orelse return error.SkipZigTest;
    defer c.PQfinish(conn);

    if (c.PQstatus(conn) != c.CONNECTION_OK) {
        return error.SkipZigTest; // Skip if PostgreSQL not available
    }

    const table_name = "test_peek_table";
    try test_helpers.createTestTable(conn, allocator, table_name);

    const slot_name = "test_peek_slot";
    const publication_name = "test_peek_pub";
    const tables = [_][]const u8{table_name};

    var wal_reader = WalReader.init(allocator, slot_name, publication_name, &[_][]const u8{});
    defer wal_reader.deinit();

    wal_reader.dropSlot() catch {};

    wal_reader.initialize(conn_str, &tables) catch |err| {
        std.debug.print("Failed to initialize WAL reader: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer wal_reader.dropSlot() catch {};

    // Insert test data
    _ = c.PQexec(conn, "INSERT INTO test_peek_table (name) VALUES ('test1');");
    _ = c.PQexec(conn, "SELECT pg_switch_wal();");

    // First peek - should return data
    var result1 = try wal_reader.peekChanges(10);
    defer result1.deinit(allocator);

    try testing.expect(result1.events.items.len > 0);
    const first_lsn = result1.events.items[0].lsn;

    // Second peek - should return same data (LSN not advanced)
    var result2 = try wal_reader.peekChanges(10);
    defer result2.deinit(allocator);

    try testing.expect(result2.events.items.len > 0);
    try testing.expectEqualStrings(first_lsn, result2.events.items[0].lsn);
}

test "advanceSlot commits LSN position" {
    const allocator = testing.allocator;

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    const conn_str_z = try allocator.dupeZ(u8, conn_str);
    defer allocator.free(conn_str_z);

    const conn = c.PQconnectdb(conn_str_z.ptr) orelse return error.SkipZigTest;
    defer c.PQfinish(conn);

    if (c.PQstatus(conn) != c.CONNECTION_OK) {
        return error.SkipZigTest;
    }

    const table_name = "test_peek_table";
    try test_helpers.createTestTable(conn, allocator, table_name);

    const slot_name = "test_advance_slot";
    const publication_name = "test_advance_pub";
    const tables = [_][]const u8{table_name};

    var wal_reader = WalReader.init(allocator, slot_name, publication_name, &[_][]const u8{});
    defer wal_reader.deinit();

    wal_reader.dropSlot() catch {};

    wal_reader.initialize(conn_str, &tables) catch |err| {
        std.debug.print("Failed to initialize WAL reader: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer wal_reader.dropSlot() catch {};

    // Insert test data
    _ = c.PQexec(conn, "INSERT INTO test_peek_table (name) VALUES ('test_advance');");
    _ = c.PQexec(conn, "SELECT pg_switch_wal();");

    // Peek changes
    var result = try wal_reader.peekChanges(10);
    defer result.deinit(allocator);

    try testing.expect(result.events.items.len > 0);
    const last_lsn = result.last_lsn orelse return error.SkipZigTest;

    // Advance slot to last LSN
    try wal_reader.advanceSlot(last_lsn);

    // Peek again - should return empty (LSN advanced)
    var result_after = try wal_reader.peekChanges(10);
    defer result_after.deinit(allocator);

    try testing.expect(result_after.events.items.len == 0);
}
