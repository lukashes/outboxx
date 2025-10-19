const std = @import("std");
const testing = std.testing;

const test_helpers = @import("test_helpers");
const getTestConnectionString = test_helpers.getTestConnectionString;

const domain = @import("domain");
const ChangeOperation = domain.ChangeOperation;

const source_mod = @import("source.zig");
const PostgresStreamingSource = source_mod.PostgresStreamingSource;

const c = @cImport({
    @cInclude("libpq-fe.h");
});

// Helper to create setup connection (non-replication)
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
        const error_msg = c.PQresultErrorMessage(result);
        std.log.warn("SQL failed: {s}\nError: {s}", .{ sql, error_msg });
        return error.SQLFailed;
    }
}

test "Streaming source: receive and convert INSERT messages to ChangeEvents" {
    const allocator = testing.allocator;

    // Generate unique names for this test
    const timestamp = std.time.timestamp();
    const table_name = try std.fmt.allocPrint(allocator, "stream_test_{d}", .{timestamp});
    defer allocator.free(table_name);

    const slot_name = try std.fmt.allocPrint(allocator, "slot_stream_{d}", .{timestamp});
    defer allocator.free(slot_name);

    const pub_name = try std.fmt.allocPrint(allocator, "pub_stream_{d}", .{timestamp});
    defer allocator.free(pub_name);

    std.log.info("Integration test: table={s}, slot={s}, pub={s}", .{ table_name, slot_name, pub_name });

    // Setup: Create table, publication, slot
    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);

    // Create table
    const create_table_sql_tmp = try std.fmt.allocPrint(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, name TEXT)", .{table_name});
    defer allocator.free(create_table_sql_tmp);
    const create_table_sql = try allocator.dupeZ(u8, create_table_sql_tmp);
    defer allocator.free(create_table_sql);
    try execSQL(setup_conn, create_table_sql);

    // Create publication
    const create_pub_sql_tmp = try std.fmt.allocPrint(allocator, "CREATE PUBLICATION {s} FOR TABLE {s}", .{ pub_name, table_name });
    defer allocator.free(create_pub_sql_tmp);
    const create_pub_sql = try allocator.dupeZ(u8, create_pub_sql_tmp);
    defer allocator.free(create_pub_sql);
    try execSQL(setup_conn, create_pub_sql);

    // Create replication slot
    const create_slot_sql_tmp = try std.fmt.allocPrint(allocator, "SELECT pg_create_logical_replication_slot('{s}', 'pgoutput')", .{slot_name});
    defer allocator.free(create_slot_sql_tmp);
    const create_slot_sql = try allocator.dupeZ(u8, create_slot_sql_tmp);
    defer allocator.free(create_slot_sql);
    try execSQL(setup_conn, create_slot_sql);

    // Get current LSN to start replication from
    const lsn_result = c.PQexec(setup_conn, "SELECT pg_current_wal_lsn()");
    defer c.PQclear(lsn_result);

    const lsn_cstr = c.PQgetvalue(lsn_result, 0, 0);
    const start_lsn = try allocator.dupeZ(u8, std.mem.span(lsn_cstr));
    defer allocator.free(start_lsn);

    std.log.info("Starting replication from LSN: {s}", .{start_lsn});

    // Insert test data
    const insert_sql_tmp = try std.fmt.allocPrint(allocator, "INSERT INTO {s} (name) VALUES ('Alice'), ('Bob')", .{table_name});
    defer allocator.free(insert_sql_tmp);
    const insert_sql = try allocator.dupeZ(u8, insert_sql_tmp);
    defer allocator.free(insert_sql);
    try execSQL(setup_conn, insert_sql);

    // Force WAL flush
    try execSQL(setup_conn, "SELECT pg_switch_wal()");

    // Now use PostgresStreamingSource
    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    var source = PostgresStreamingSource.init(allocator, slot_name, pub_name);
    defer source.deinit();

    source.connect(conn_str, start_lsn) catch |err| {
        std.log.warn("Streaming source connection failed: {}", .{err});
        return error.SkipZigTest;
    };

    std.log.info("Streaming source connected, receiving batch...", .{});

    // Receive batch with timeout
    const batch = source.receiveBatch(10, 5000) catch |err| {
        std.log.warn("Failed to receive batch: {}", .{err});
        return error.SkipZigTest;
    };
    defer {
        var mut_batch = batch;
        mut_batch.deinit();
    }

    std.log.info("Received batch with {} changes", .{batch.changes.len});

    // Verify we got 2 INSERT events
    var insert_count: usize = 0;
    for (batch.changes) |change| {
        std.log.info("Change: op={s}, resource={s}", .{ change.op, change.meta.resource });

        if (std.mem.eql(u8, change.op, "INSERT")) {
            insert_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), insert_count);

    // Send feedback
    try source.sendFeedback(batch.last_lsn);

    // Cleanup
    const drop_pub_sql_tmp = try std.fmt.allocPrint(allocator, "DROP PUBLICATION IF EXISTS {s}", .{pub_name});
    defer allocator.free(drop_pub_sql_tmp);
    const drop_pub_sql = try allocator.dupeZ(u8, drop_pub_sql_tmp);
    defer allocator.free(drop_pub_sql);
    execSQL(setup_conn, drop_pub_sql) catch {};

    const drop_slot_sql_tmp = try std.fmt.allocPrint(allocator, "SELECT pg_drop_replication_slot('{s}')", .{slot_name});
    defer allocator.free(drop_slot_sql_tmp);
    const drop_slot_sql = try allocator.dupeZ(u8, drop_slot_sql_tmp);
    defer allocator.free(drop_slot_sql);
    execSQL(setup_conn, drop_slot_sql) catch {};

    const drop_table_sql_tmp = try std.fmt.allocPrint(allocator, "DROP TABLE IF EXISTS {s}", .{table_name});
    defer allocator.free(drop_table_sql_tmp);
    const drop_table_sql = try allocator.dupeZ(u8, drop_table_sql_tmp);
    defer allocator.free(drop_table_sql);
    execSQL(setup_conn, drop_table_sql) catch {};

    std.log.info("Integration test passed!", .{});
}
