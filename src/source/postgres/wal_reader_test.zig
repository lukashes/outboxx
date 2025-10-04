const std = @import("std");
const testing = std.testing;

const reader = @import("wal_reader.zig");
const WalReader = reader.WalReader;
const WalEvent = reader.WalEvent;

test "WalReader.init" {
    const allocator = testing.allocator;
    const slot_name = "test_slot";
    const publication_name = "test_publication";

    const wal_reader = WalReader.init(allocator, slot_name, publication_name, "test_table");

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
const c = @cImport({
    @cInclude("libpq-fe.h");
});

fn getTestConnectionString(allocator: std.mem.Allocator) ![]const u8 {
    const password = std.process.getEnvVarOwned(allocator, "POSTGRES_PASSWORD") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "password"),
        else => return err,
    };
    defer allocator.free(password);

    return std.fmt.allocPrint(
        allocator,
        "host=localhost port=5432 dbname=outboxx_test user=postgres password={s}",
        .{password},
    );
}

fn createTestTable(conn: *c.PGconn) !void {
    const result = c.PQexec(conn, "DROP TABLE IF EXISTS test_peek_table;");
    defer c.PQclear(result);

    const result2 = c.PQexec(conn,
        \\CREATE TABLE test_peek_table (
        \\  id SERIAL PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  created_at TIMESTAMP DEFAULT NOW()
        \\);
    );
    defer c.PQclear(result2);

    const result3 = c.PQexec(conn, "ALTER TABLE test_peek_table REPLICA IDENTITY FULL;");
    defer c.PQclear(result3);
}

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

    try createTestTable(conn);

    const slot_name = "test_peek_slot";
    const publication_name = "test_peek_pub";

    var wal_reader = WalReader.init(allocator, slot_name, publication_name, "test_peek_table");
    defer wal_reader.deinit();

    wal_reader.dropSlot() catch {};

    wal_reader.initialize(conn_str) catch |err| {
        std.debug.print("Failed to initialize WAL reader: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer wal_reader.dropSlot() catch {};

    // Insert test data
    _ = c.PQexec(conn, "INSERT INTO test_peek_table (name) VALUES ('test1');");
    _ = c.PQexec(conn, "SELECT pg_switch_wal();");

    // First peek - should return data
    var changes1 = try wal_reader.peekChanges(10);
    defer {
        for (changes1.items) |*change| {
            change.deinit(allocator);
        }
        changes1.deinit(allocator);
    }

    try testing.expect(changes1.items.len > 0);
    const first_lsn = changes1.items[0].lsn;

    // Second peek - should return same data (LSN not advanced)
    var changes2 = try wal_reader.peekChanges(10);
    defer {
        for (changes2.items) |*change| {
            change.deinit(allocator);
        }
        changes2.deinit(allocator);
    }

    try testing.expect(changes2.items.len > 0);
    try testing.expectEqualStrings(first_lsn, changes2.items[0].lsn);
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

    try createTestTable(conn);

    const slot_name = "test_advance_slot";
    const publication_name = "test_advance_pub";

    var wal_reader = WalReader.init(allocator, slot_name, publication_name, "test_peek_table");
    defer wal_reader.deinit();

    wal_reader.dropSlot() catch {};

    wal_reader.initialize(conn_str) catch |err| {
        std.debug.print("Failed to initialize WAL reader: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer wal_reader.dropSlot() catch {};

    // Insert test data
    _ = c.PQexec(conn, "INSERT INTO test_peek_table (name) VALUES ('test_advance');");
    _ = c.PQexec(conn, "SELECT pg_switch_wal();");

    // Peek changes
    var changes = try wal_reader.peekChanges(10);
    defer {
        for (changes.items) |*change| {
            change.deinit(allocator);
        }
        changes.deinit(allocator);
    }

    try testing.expect(changes.items.len > 0);
    const last_lsn = changes.items[changes.items.len - 1].lsn;

    // Advance slot to last LSN
    try wal_reader.advanceSlot(last_lsn);

    // Peek again - should return empty (LSN advanced)
    var changes_after = try wal_reader.peekChanges(10);
    defer {
        for (changes_after.items) |*change| {
            change.deinit(allocator);
        }
        changes_after.deinit(allocator);
    }

    try testing.expect(changes_after.items.len == 0);
}
