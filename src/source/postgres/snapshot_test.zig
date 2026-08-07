const std = @import("std");
const testing = std.testing;

const test_helpers = @import("../../testing/test_helpers.zig");
const getTestConnectionString = test_helpers.getTestConnectionString;

const domain = @import("../../domain/change_event.zig");
const RowDataHelpers = domain.RowDataHelpers;

const SnapshotSession = @import("snapshot.zig").SnapshotSession;
const PostgresSource = @import("source.zig").PostgresSource;

const c = @import("c"); // C bindings (build-system translate-c)

fn publicationExists(conn: *c.PGconn, allocator: std.mem.Allocator, name: []const u8) !bool {
    const sql = try std.fmt.allocPrintSentinel(allocator, "SELECT 1 FROM pg_publication WHERE pubname = '{s}'", .{name}, 0);
    defer allocator.free(sql);
    const result = c.PQexec(conn, sql.ptr);
    defer c.PQclear(result);
    return c.PQntuples(result) > 0;
}

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

test "SnapshotSession: reads existing rows as READ events, consistent with the exported snapshot" {
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

    const resources = [_][]const u8{resource};
    var session = SnapshotSession.init(allocator, snapshot_name, lsn, timestamp, &resources);
    defer session.deinit();
    try session.connect(conn_str);

    // One arena for the whole read; a small fetch limit forces several FETCH round
    // trips over the five rows.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var seen = [_]bool{false} ** 7; // ids 1..5 expected; 6 must stay unseen
    var total: usize = 0;
    while (true) {
        const events = try session.next(arena.allocator(), 2);
        if (events.len == 0) break;

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

    try testing.expectEqual(@as(usize, 5), total);
    for (1..6) |i| try testing.expect(seen[i]);
    try testing.expect(!seen[6]);
}

test "SnapshotSession: empty table yields no events" {
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

    const resources = [_][]const u8{resource};
    var session = SnapshotSession.init(allocator, snapshot_name, "0/0", test_helpers.nowSeconds(io), &resources);
    defer session.deinit();
    try session.connect(conn_str);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try testing.expectEqual(@as(usize, 0), (try session.next(arena.allocator(), 10)).len);
}

test "SnapshotSession: reads several resources in one session" {
    const allocator = testing.allocator;
    const io = testing.io;

    const suffix = test_helpers.nowMicros(io);
    const first_table = try std.fmt.allocPrint(allocator, "snap_multi_a_{d}", .{suffix});
    defer allocator.free(first_table);
    const second_table = try std.fmt.allocPrint(allocator, "snap_multi_b_{d}", .{suffix});
    defer allocator.free(second_table);

    const first_resource = try std.fmt.allocPrint(allocator, "public.{s}", .{first_table});
    defer allocator.free(first_resource);
    const second_resource = try std.fmt.allocPrint(allocator, "public.{s}", .{second_table});
    defer allocator.free(second_resource);

    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);
    defer {
        const drop = std.fmt.allocPrintSentinel(allocator, "DROP TABLE IF EXISTS {s}; DROP TABLE IF EXISTS {s};", .{ first_table, second_table }, 0) catch unreachable;
        defer allocator.free(drop);
        execSQL(setup_conn, drop) catch {};
    }

    // Two rows each, so a fetch limit of 1 forces the session to cross from one
    // cursor to the next mid-read.
    for ([_][]const u8{ first_table, second_table }) |table| {
        const create = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, name TEXT)", .{table});
        defer allocator.free(create);
        try execSQL(setup_conn, create);

        const seed = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name) VALUES ('one'), ('two')", .{table});
        defer allocator.free(seed);
        try execSQL(setup_conn, seed);
    }

    const export_conn = try createSetupConnection(allocator);
    defer c.PQfinish(export_conn);
    try execSQL(export_conn, "BEGIN ISOLATION LEVEL REPEATABLE READ");
    const export_result = c.PQexec(export_conn, "SELECT pg_export_snapshot()");
    defer c.PQclear(export_result);
    const snapshot_name = try allocator.dupe(u8, std.mem.span(c.PQgetvalue(export_result, 0, 0)));
    defer allocator.free(snapshot_name);

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    const resources = [_][]const u8{ first_resource, second_resource };
    var session = SnapshotSession.init(allocator, snapshot_name, "0/0", test_helpers.nowSeconds(io), &resources);
    defer session.deinit();
    try session.connect(conn_str);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var per_resource = [_]usize{ 0, 0 };
    while (true) {
        const events = try session.next(arena.allocator(), 1);
        if (events.len == 0) break;

        for (events) |event| {
            try testing.expectEqualStrings("READ", event.op);
            if (std.mem.eql(u8, event.meta.resource, first_resource)) {
                per_resource[0] += 1;
            } else if (std.mem.eql(u8, event.meta.resource, second_resource)) {
                per_resource[1] += 1;
            } else {
                return error.UnexpectedResource;
            }
        }
    }

    try testing.expectEqual(@as(usize, 2), per_resource[0]);
    try testing.expectEqual(@as(usize, 2), per_resource[1]);
}

test "reconciliation: an interrupted snapshot drops the orphaned slot and recreates it" {
    const allocator = testing.allocator;
    const io = testing.io;

    const suffix = test_helpers.nowMicros(io);
    const slot_name = try std.fmt.allocPrint(allocator, "recon_slot_{d}", .{suffix});
    defer allocator.free(slot_name);
    const pub_name = try std.fmt.allocPrint(allocator, "recon_pub_{d}", .{suffix});
    defer allocator.free(pub_name);
    const marker_name = try std.fmt.allocPrint(allocator, "{s}_snapshotting", .{slot_name});
    defer allocator.free(marker_name);

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);
    defer {
        const drop = std.fmt.allocPrintSentinel(allocator, "SELECT pg_drop_replication_slot('{s}') FROM pg_replication_slots WHERE slot_name='{s}'; DROP PUBLICATION IF EXISTS {s}; DROP PUBLICATION IF EXISTS {s};", .{ slot_name, slot_name, pub_name, marker_name }, 0) catch unreachable;
        defer allocator.free(drop);
        _ = c.PQexec(setup_conn, drop.ptr);
    }

    // First bootstrap: creates the streaming publication, the snapshot marker, and
    // the slot, then "crashes" (deinit without finishSnapshot or streaming).
    const first_lsn = blk: {
        var source = PostgresSource.init(allocator, slot_name, pub_name);
        defer source.deinit();
        try source.connect(conn_str, true);
        try testing.expect(source.startLsn() != null); // fresh slot
        break :blk try allocator.dupe(u8, source.startLsn().?);
    };
    defer allocator.free(first_lsn);

    // Marker and slot survive the crash: the bootstrap is not marked complete.
    try testing.expect(try publicationExists(setup_conn, allocator, marker_name));

    // Move the WAL so a recreated slot lands on a later consistent point.
    try execSQL(setup_conn, "SELECT pg_logical_emit_message(true, 'outboxx', 'recon')");

    // Second start with the same names: the marker signals an interrupted snapshot,
    // so the orphaned slot is dropped and a fresh one is created.
    {
        var source = PostgresSource.init(allocator, slot_name, pub_name);
        defer source.deinit();
        try source.connect(conn_str, true);
        try testing.expect(source.startLsn() != null); // redo -> a fresh slot
        try testing.expect(!std.mem.eql(u8, first_lsn, source.startLsn().?));
    }

    // Still mid-bootstrap: the marker stays until a snapshot completes.
    try testing.expect(try publicationExists(setup_conn, allocator, marker_name));
}

test "reconciliation: a completed snapshot resumes without recreating the slot" {
    const allocator = testing.allocator;
    const io = testing.io;

    const suffix = test_helpers.nowMicros(io);
    const slot_name = try std.fmt.allocPrint(allocator, "recon_done_slot_{d}", .{suffix});
    defer allocator.free(slot_name);
    const pub_name = try std.fmt.allocPrint(allocator, "recon_done_pub_{d}", .{suffix});
    defer allocator.free(pub_name);
    const marker_name = try std.fmt.allocPrint(allocator, "{s}_snapshotting", .{slot_name});
    defer allocator.free(marker_name);

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);
    defer {
        const drop = std.fmt.allocPrintSentinel(allocator, "SELECT pg_drop_replication_slot('{s}') FROM pg_replication_slots WHERE slot_name='{s}'; DROP PUBLICATION IF EXISTS {s}; DROP PUBLICATION IF EXISTS {s};", .{ slot_name, slot_name, pub_name, marker_name }, 0) catch unreachable;
        defer allocator.free(drop);
        _ = c.PQexec(setup_conn, drop.ptr);
    }

    // First bootstrap that completes: finishSnapshot drops the marker.
    {
        var source = PostgresSource.init(allocator, slot_name, pub_name);
        defer source.deinit();
        try source.connect(conn_str, true);
        try testing.expect(source.startLsn() != null);
        try source.finishSnapshot();
    }

    // Marker gone, streaming publication remains: steady state is one publication.
    try testing.expect(!try publicationExists(setup_conn, allocator, marker_name));
    try testing.expect(try publicationExists(setup_conn, allocator, pub_name));

    // Second start: slot exists and no marker -> resume, no re-snapshot.
    {
        var source = PostgresSource.init(allocator, slot_name, pub_name);
        defer source.deinit();
        try source.connect(conn_str, true);
        try testing.expect(source.startLsn() == null); // resumed, not recreated
    }
}
