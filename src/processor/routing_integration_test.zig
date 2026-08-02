const std = @import("std");
const testing = std.testing;

const test_helpers = @import("../testing/test_helpers.zig");
const getTestConnectionString = test_helpers.getTestConnectionString;

const PostgresSource = @import("../source/postgres/source.zig").PostgresSource;
const matchStreams = @import("processor.zig").matchStreams;
const Stream = @import("../config/config.zig").Stream;

const c = @import("c"); // C bindings (build-system translate-c)

// Source is imported through the postgres_source module (not a relative path) so
// this file and cdc_processor share one instance of source.zig, avoiding the
// "file exists in two modules" error.

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

test "matchStreams: a change from another schema is not routed to a public stream" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(@intCast(test_helpers.nowMicros(std.testing.io)));
    const random_suffix = prng.random().int(u32);
    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "xschema_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(table_name);
    const other_schema = try std.fmt.allocPrint(allocator, "other_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(other_schema);
    const slot_name = try std.fmt.allocPrint(allocator, "slot_xschema_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(slot_name);
    const pub_name = try std.fmt.allocPrint(allocator, "pub_xschema_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(pub_name);

    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);
    defer {
        const drop_pub = std.fmt.allocPrintSentinel(allocator, "DROP PUBLICATION IF EXISTS {s}", .{pub_name}, 0) catch unreachable;
        defer allocator.free(drop_pub);
        execSQL(setup_conn, drop_pub) catch {};
        const drop_slot = std.fmt.allocPrintSentinel(allocator, "SELECT pg_drop_replication_slot('{s}')", .{slot_name}, 0) catch unreachable;
        defer allocator.free(drop_slot);
        execSQL(setup_conn, drop_slot) catch {};
        // Dropping the schema CASCADE also drops the other-schema table; the
        // public table is dropped separately.
        const drop_schema = std.fmt.allocPrintSentinel(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{other_schema}, 0) catch unreachable;
        defer allocator.free(drop_schema);
        execSQL(setup_conn, drop_schema) catch {};
        const drop_public = std.fmt.allocPrintSentinel(allocator, "DROP TABLE IF EXISTS {s}", .{table_name}, 0) catch unreachable;
        defer allocator.free(drop_public);
        execSQL(setup_conn, drop_public) catch {};
    }

    // public.<table>: what the stream targets. A same-named table in another
    // schema is also published, so its change reaches the decoder and must be
    // dropped by matchStreams, not routed as if it were public.<table>.
    const create_public = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, name TEXT)", .{table_name});
    defer allocator.free(create_public);
    try execSQL(setup_conn, create_public);

    const create_schema = try test_helpers.formatSqlZ(allocator, "CREATE SCHEMA {s}", .{other_schema});
    defer allocator.free(create_schema);
    try execSQL(setup_conn, create_schema);

    const create_other = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s}.{s} (id SERIAL PRIMARY KEY, name TEXT)", .{ other_schema, table_name });
    defer allocator.free(create_other);
    try execSQL(setup_conn, create_other);

    const create_pub = try test_helpers.formatSqlZ(allocator, "CREATE PUBLICATION {s} FOR TABLE {s}, {s}.{s}", .{ pub_name, table_name, other_schema, table_name });
    defer allocator.free(create_pub);
    try execSQL(setup_conn, create_pub);

    const create_slot = try test_helpers.formatSqlZ(allocator, "SELECT pg_create_logical_replication_slot('{s}', 'pgoutput')", .{slot_name});
    defer allocator.free(create_slot);
    try execSQL(setup_conn, create_slot);

    const lsn_result = c.PQexec(setup_conn, "SELECT pg_current_wal_lsn()");
    defer c.PQclear(lsn_result);
    const start_lsn = try allocator.dupeZ(u8, std.mem.span(c.PQgetvalue(lsn_result, 0, 0)));
    defer allocator.free(start_lsn);

    const insert_public = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name) VALUES ('PublicRow')", .{table_name});
    defer allocator.free(insert_public);
    try execSQL(setup_conn, insert_public);
    const insert_other = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s}.{s} (name) VALUES ('OtherRow')", .{ other_schema, table_name });
    defer allocator.free(insert_other);
    try execSQL(setup_conn, insert_other);
    try execSQL(setup_conn, "SELECT pg_switch_wal()");

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer source.deinit();
    try source.connect(conn_str, start_lsn);

    const batch = try source.receiveBatch(std.testing.io, allocator, 10);
    defer {
        var mut_batch = batch;
        mut_batch.deinit();
    }

    const stream = try test_helpers.createTestStreamConfig(allocator, table_name, "unused_topic");
    defer allocator.free(stream.name);
    const streams = [_]Stream{stream};

    // Both inserts arrive tagged with their real schema; only the public one
    // matches the stream, the other-schema change matches nothing.
    var public_matched: usize = 0;
    var other_dropped: usize = 0;
    for (batch.changes) |change| {
        var matched = try matchStreams(allocator, &streams, change);
        defer matched.deinit(allocator);

        if (std.mem.eql(u8, change.meta.schema, "public")) {
            try testing.expectEqual(@as(usize, 1), matched.items.len);
            public_matched += 1;
        } else {
            try testing.expectEqualStrings(other_schema, change.meta.schema);
            try testing.expectEqual(@as(usize, 0), matched.items.len);
            other_dropped += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), public_matched);
    try testing.expectEqual(@as(usize, 1), other_dropped);
}
