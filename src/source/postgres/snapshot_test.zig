const std = @import("std");
const testing = std.testing;

const test_helpers = @import("../../testing/test_helpers.zig");
const getTestConnectionString = test_helpers.getTestConnectionString;

const domain = @import("../../domain/change_event.zig");
const RowDataHelpers = domain.RowDataHelpers;

const SnapshotReader = @import("snapshot.zig").SnapshotReader;

const c = @import("c"); // C bindings (build-system translate-c)

fn createSetupConnection(allocator: std.mem.Allocator) !*c.PGconn {
    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);
    const conn_str_z = try allocator.dupeZ(u8, conn_str);
    defer allocator.free(conn_str_z);

    const conn = c.PQconnectdb(conn_str_z.ptr) orelse return error.ConnectionFailed;
    if (c.PQstatus(conn) != c.CONNECTION_OK) {
        c.PQfinish(conn);
        return error.ConnectionFailed;
    }
    return conn;
}

fn execSQL(conn: *c.PGconn, sql: [:0]const u8) !void {
    const result = c.PQexec(conn, sql.ptr);
    defer c.PQclear(result);
    const status = c.PQresultStatus(result);
    if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
        std.log.warn("SQL failed: {s}\nError: {s}", .{ sql, c.PQresultErrorMessage(result) });
        return error.SQLFailed;
    }
}

test "SnapshotReader: reads existing rows as READ events, consistent with the exported snapshot" {
    const allocator = testing.allocator;
    const io = testing.io;

    const suffix = test_helpers.nowMicros(io);
    const table_name = try std.fmt.allocPrint(allocator, "snap_{d}", .{suffix});
    defer allocator.free(table_name);
    const resource = try std.fmt.allocPrint(allocator, "public.{s}", .{table_name});
    defer allocator.free(resource);

    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);
    defer {
        const drop = std.fmt.allocPrintSentinel(allocator, "DROP TABLE IF EXISTS {s}", .{table_name}, 0) catch unreachable;
        defer allocator.free(drop);
        execSQL(setup_conn, drop) catch {};
    }

    const create = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, name TEXT, active BOOL, ratio DOUBLE PRECISION)", .{table_name});
    defer allocator.free(create);
    try execSQL(setup_conn, create);

    // Five committed rows the snapshot must see, typed to exercise mapValue.
    const seed = try test_helpers.formatSqlZ(allocator,
        \\INSERT INTO {s} (name, active, ratio) VALUES
        \\ ('name_1', true, 1.5),
        \\ ('name_2', false, 2.5),
        \\ ('name_3', true, 3.5),
        \\ ('name_4', false, 4.5),
        \\ ('name_5', true, 5.5)
    , .{table_name});
    defer allocator.free(seed);
    try execSQL(setup_conn, seed);

    // Export a snapshot from a held-open transaction, standing in for the one
    // CREATE_REPLICATION_SLOT exports. It must stay open until the reader runs
    // SET TRANSACTION SNAPSHOT.
    const export_conn = try createSetupConnection(allocator);
    defer c.PQfinish(export_conn);
    try execSQL(export_conn, "BEGIN ISOLATION LEVEL REPEATABLE READ");
    const export_result = c.PQexec(export_conn, "SELECT pg_export_snapshot()");
    defer c.PQclear(export_result);
    try testing.expect(c.PQresultStatus(export_result) == c.PGRES_TUPLES_OK);
    const snapshot_name = try allocator.dupe(u8, std.mem.span(c.PQgetvalue(export_result, 0, 0)));
    defer allocator.free(snapshot_name);

    // A sixth row inserted after the export: outside the snapshot, so the reader
    // must not see it.
    const after = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, active, ratio) VALUES ('name_6', false, 6.5)", .{table_name});
    defer allocator.free(after);
    try execSQL(setup_conn, after);

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    const lsn = "0/15D6E10";
    const timestamp = test_helpers.nowSeconds(io);

    var reader = SnapshotReader.init(allocator, snapshot_name, lsn, timestamp);
    defer reader.deinit();
    try reader.connect(conn_str);
    var table = try reader.open(resource);

    // One arena for the whole read; a small fetch limit forces several FETCH round
    // trips over the five rows.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var seen = [_]bool{false} ** 7; // ids 1..5 expected; 6 must stay unseen
    var total: usize = 0;
    while (try table.next(arena.allocator(), 2)) |events| {
        for (events) |event| {
            try testing.expectEqualStrings("READ", event.op);
            try testing.expectEqualStrings(resource, event.meta.resource);
            try testing.expectEqualStrings(lsn, event.meta.lsn.?);
            try testing.expectEqual(timestamp, event.meta.timestamp);

            try testing.expect(event.data == .insert);
            const row = event.data.insert;

            const id = RowDataHelpers.getField(row, "id").?.integer;
            try testing.expect(id >= 1 and id <= 5);
            try testing.expect(!seen[@intCast(id)]);
            seen[@intCast(id)] = true;

            // name typed as string, active as bool, ratio as float, same as the
            // streamed path would map them.
            var name_buf: [16]u8 = undefined;
            const expected_name = try std.fmt.bufPrint(&name_buf, "name_{d}", .{id});
            try testing.expectEqualStrings(expected_name, RowDataHelpers.getField(row, "name").?.string);
            try testing.expect(RowDataHelpers.getField(row, "active").? == .bool);
            try testing.expect(RowDataHelpers.getField(row, "ratio").? == .float);

            total += 1;
        }
    }
    try table.close();

    try testing.expectEqual(@as(usize, 5), total);
    for (1..6) |i| try testing.expect(seen[i]);
    try testing.expect(!seen[6]);
}

test "SnapshotReader: empty table yields no events" {
    const allocator = testing.allocator;
    const io = testing.io;

    const suffix = test_helpers.nowMicros(io);
    const table_name = try std.fmt.allocPrint(allocator, "snap_empty_{d}", .{suffix});
    defer allocator.free(table_name);
    const resource = try std.fmt.allocPrint(allocator, "public.{s}", .{table_name});
    defer allocator.free(resource);

    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);
    defer {
        const drop = std.fmt.allocPrintSentinel(allocator, "DROP TABLE IF EXISTS {s}", .{table_name}, 0) catch unreachable;
        defer allocator.free(drop);
        execSQL(setup_conn, drop) catch {};
    }

    const create = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, name TEXT)", .{table_name});
    defer allocator.free(create);
    try execSQL(setup_conn, create);

    const export_conn = try createSetupConnection(allocator);
    defer c.PQfinish(export_conn);
    try execSQL(export_conn, "BEGIN ISOLATION LEVEL REPEATABLE READ");
    const export_result = c.PQexec(export_conn, "SELECT pg_export_snapshot()");
    defer c.PQclear(export_result);
    const snapshot_name = try allocator.dupe(u8, std.mem.span(c.PQgetvalue(export_result, 0, 0)));
    defer allocator.free(snapshot_name);

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    var reader = SnapshotReader.init(allocator, snapshot_name, "0/0", test_helpers.nowSeconds(io));
    defer reader.deinit();
    try reader.connect(conn_str);
    var table = try reader.open(resource);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try testing.expect((try table.next(arena.allocator(), 10)) == null);
    try table.close();
}
