const std = @import("std");
const testing = std.testing;

const test_helpers = @import("test_helpers");
const getTestConnectionString = test_helpers.getTestConnectionString;

const domain = @import("domain");
const ChangeOperation = domain.ChangeOperation;

const constants = @import("constants");

const source_mod = @import("source.zig");
const PostgresSource = source_mod.PostgresSource;

const c = @import("c"); // C bindings (build-system translate-c)

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

// Helper to cleanup test environment (drop slot, publication, table)
fn cleanupTestEnvironment(
    allocator: std.mem.Allocator,
    setup_conn: *c.PGconn,
    table_name: []const u8,
    slot_name: []const u8,
    pub_name: []const u8,
) void {
    // Drop publication
    if (std.fmt.allocPrint(allocator, "DROP PUBLICATION IF EXISTS {s}", .{pub_name})) |drop_pub_sql_tmp| {
        defer allocator.free(drop_pub_sql_tmp);
        if (allocator.dupeZ(u8, drop_pub_sql_tmp)) |drop_pub_sql| {
            defer allocator.free(drop_pub_sql);
            execSQL(setup_conn, drop_pub_sql) catch {};
        } else |_| {}
    } else |_| {}

    // Drop replication slot
    if (std.fmt.allocPrint(allocator, "SELECT pg_drop_replication_slot('{s}')", .{slot_name})) |drop_slot_sql_tmp| {
        defer allocator.free(drop_slot_sql_tmp);
        if (allocator.dupeZ(u8, drop_slot_sql_tmp)) |drop_slot_sql| {
            defer allocator.free(drop_slot_sql);
            execSQL(setup_conn, drop_slot_sql) catch {};
        } else |_| {}
    } else |_| {}

    // Drop table
    if (std.fmt.allocPrint(allocator, "DROP TABLE IF EXISTS {s}", .{table_name})) |drop_table_sql_tmp| {
        defer allocator.free(drop_table_sql_tmp);
        if (allocator.dupeZ(u8, drop_table_sql_tmp)) |drop_table_sql| {
            defer allocator.free(drop_table_sql);
            execSQL(setup_conn, drop_table_sql) catch {};
        } else |_| {}
    } else |_| {}
}

// Return a string field's value by name, or null if absent / non-string.
fn fieldValue(row: domain.RowData, name: []const u8) ?[]const u8 {
    for (row) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return switch (field.value) {
                .string => |s| s,
                else => null,
            };
        }
    }
    return null;
}

test "Streaming source: receive and convert INSERT messages to ChangeEvents" {
    const allocator = testing.allocator;

    // Generate unique names for this test (timestamp + random to avoid collisions)
    var prng = std.Random.DefaultPrng.init(@intCast(test_helpers.nowMicros(std.testing.io)));
    const random_suffix = prng.random().int(u32);
    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "stream_test_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(table_name);

    const slot_name = try std.fmt.allocPrint(allocator, "slot_stream_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(slot_name);

    const pub_name = try std.fmt.allocPrint(allocator, "pub_stream_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(pub_name);

    std.log.info("Integration test: table={s}, slot={s}, pub={s}", .{ table_name, slot_name, pub_name });

    // Setup: Create table, publication, slot
    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);

    // Cleanup defer - declared FIRST, executes LAST (after source.deinit)
    defer cleanupTestEnvironment(allocator, setup_conn, table_name, slot_name, pub_name);

    // Create table
    const create_table_sql = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, name TEXT)", .{table_name});
    defer allocator.free(create_table_sql);
    try execSQL(setup_conn, create_table_sql);

    // Create publication
    const create_pub_sql = try test_helpers.formatSqlZ(allocator, "CREATE PUBLICATION {s} FOR TABLE {s}", .{ pub_name, table_name });
    defer allocator.free(create_pub_sql);
    try execSQL(setup_conn, create_pub_sql);

    // Create replication slot
    const create_slot_sql = try test_helpers.formatSqlZ(allocator, "SELECT pg_create_logical_replication_slot('{s}', 'pgoutput')", .{slot_name});
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
    const insert_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name) VALUES ('Alice'), ('Bob')", .{table_name});
    defer allocator.free(insert_sql);
    try execSQL(setup_conn, insert_sql);

    // Force WAL flush
    try execSQL(setup_conn, "SELECT pg_switch_wal()");

    // Now use PostgresStreamingSource
    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer source.deinit(); // Source defer - declared SECOND, executes FIRST (before cleanup)

    try source.connect(conn_str, start_lsn);

    std.log.info("Streaming source connected, receiving batch...", .{});

    const batch = try source.receiveBatch(std.testing.io, allocator, 10, 0);
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
    try source.sendFeedback(std.testing.io, batch.last_lsn);

    std.log.info("Integration test passed!", .{});
}

test "Streaming source: UPDATE operation E2E with old and new tuples" {
    const allocator = testing.allocator;

    // Generate unique names for this test (timestamp + random to avoid collisions)
    var prng = std.Random.DefaultPrng.init(@intCast(test_helpers.nowMicros(std.testing.io)));
    const random_suffix = prng.random().int(u32);
    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "stream_update_test_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(table_name);

    const slot_name = try std.fmt.allocPrint(allocator, "slot_update_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(slot_name);

    const pub_name = try std.fmt.allocPrint(allocator, "pub_update_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(pub_name);

    std.log.info("UPDATE E2E test: table={s}, slot={s}, pub={s}", .{ table_name, slot_name, pub_name });

    // Setup connection
    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);

    // Cleanup defer - declared FIRST, executes LAST (after source.deinit)
    defer cleanupTestEnvironment(allocator, setup_conn, table_name, slot_name, pub_name);

    // Create table with REPLICA IDENTITY FULL to get old tuple
    const create_table_sql = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, name TEXT)", .{table_name});
    defer allocator.free(create_table_sql);
    try execSQL(setup_conn, create_table_sql);

    // Set REPLICA IDENTITY FULL to get old tuple in UPDATE messages
    const replica_identity_sql = try test_helpers.formatSqlZ(allocator, "ALTER TABLE {s} REPLICA IDENTITY FULL", .{table_name});
    defer allocator.free(replica_identity_sql);
    try execSQL(setup_conn, replica_identity_sql);

    // Create publication
    const create_pub_sql = try test_helpers.formatSqlZ(allocator, "CREATE PUBLICATION {s} FOR TABLE {s}", .{ pub_name, table_name });
    defer allocator.free(create_pub_sql);
    try execSQL(setup_conn, create_pub_sql);

    // Create replication slot
    const create_slot_sql = try test_helpers.formatSqlZ(allocator, "SELECT pg_create_logical_replication_slot('{s}', 'pgoutput')", .{slot_name});
    defer allocator.free(create_slot_sql);
    try execSQL(setup_conn, create_slot_sql);

    // Get current LSN
    const lsn_result = c.PQexec(setup_conn, "SELECT pg_current_wal_lsn()");
    defer c.PQclear(lsn_result);
    const lsn_cstr = c.PQgetvalue(lsn_result, 0, 0);
    const start_lsn = try allocator.dupeZ(u8, std.mem.span(lsn_cstr));
    defer allocator.free(start_lsn);

    // Insert initial row
    const insert_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (id, name) VALUES (1, 'Alice')", .{table_name});
    defer allocator.free(insert_sql);
    try execSQL(setup_conn, insert_sql);

    // Update the row: Alice -> Bob
    const update_sql = try test_helpers.formatSqlZ(allocator, "UPDATE {s} SET name = 'Bob' WHERE id = 1", .{table_name});
    defer allocator.free(update_sql);
    try execSQL(setup_conn, update_sql);

    // Force WAL flush
    try execSQL(setup_conn, "SELECT pg_switch_wal()");

    // Connect streaming source
    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer source.deinit();

    try source.connect(conn_str, start_lsn);

    const batch = try source.receiveBatch(std.testing.io, allocator, 10, 0);
    defer {
        var mut_batch = batch;
        mut_batch.deinit();
    }

    std.log.info("Received batch with {} changes", .{batch.changes.len});

    // Find UPDATE event
    var found_update = false;
    for (batch.changes) |change| {
        std.log.info("Change: op={s}, resource={s}", .{ change.op, change.meta.resource });

        if (std.mem.eql(u8, change.op, "UPDATE")) {
            found_update = true;

            // Verify UPDATE structure
            try testing.expect(change.data == .update);

            const new_data = change.data.update.new;
            const old_data = change.data.update.old;

            // Find name field in old_data
            var old_name: ?[]const u8 = null;
            for (old_data) |field| {
                if (std.mem.eql(u8, field.name, "name")) {
                    try testing.expect(field.value == .string);
                    old_name = field.value.string;
                }
            }

            // Find name field in new_data
            var new_name: ?[]const u8 = null;
            for (new_data) |field| {
                if (std.mem.eql(u8, field.name, "name")) {
                    try testing.expect(field.value == .string);
                    new_name = field.value.string;
                }
            }

            // Verify old_name = Alice, new_name = Bob
            try testing.expect(old_name != null);
            try testing.expect(new_name != null);
            try testing.expectEqualStrings("Alice", old_name.?);
            try testing.expectEqualStrings("Bob", new_name.?);
        }
    }

    try testing.expect(found_update);

    // Send feedback
    try source.sendFeedback(std.testing.io, batch.last_lsn);

    std.log.info("UPDATE E2E test passed!", .{});
}

test "Streaming source: unchanged TOAST column becomes the placeholder" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(@intCast(test_helpers.nowMicros(std.testing.io)));
    const random_suffix = prng.random().int(u32);
    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "stream_toast_test_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(table_name);

    const slot_name = try std.fmt.allocPrint(allocator, "slot_toast_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(slot_name);

    const pub_name = try std.fmt.allocPrint(allocator, "pub_toast_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(pub_name);

    std.log.info("TOAST E2E test: table={s}, slot={s}, pub={s}", .{ table_name, slot_name, pub_name });

    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);

    // Cleanup defer - declared FIRST, executes LAST (after source.deinit)
    defer cleanupTestEnvironment(allocator, setup_conn, table_name, slot_name, pub_name);

    // Table with a large text column. STORAGE EXTERNAL disables compression, so a
    // 4KB value is guaranteed to be stored out-of-line (TOAST) and reported as
    // unchanged on an UPDATE that doesn't touch it. REPLICA IDENTITY FULL to get old tuples.
    const create_table_sql = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, name TEXT, toast_field TEXT)", .{table_name});
    defer allocator.free(create_table_sql);
    try execSQL(setup_conn, create_table_sql);

    const storage_sql = try test_helpers.formatSqlZ(allocator, "ALTER TABLE {s} ALTER COLUMN toast_field SET STORAGE EXTERNAL", .{table_name});
    defer allocator.free(storage_sql);
    try execSQL(setup_conn, storage_sql);

    const replica_identity_sql = try test_helpers.formatSqlZ(allocator, "ALTER TABLE {s} REPLICA IDENTITY FULL", .{table_name});
    defer allocator.free(replica_identity_sql);
    try execSQL(setup_conn, replica_identity_sql);

    const create_pub_sql = try test_helpers.formatSqlZ(allocator, "CREATE PUBLICATION {s} FOR TABLE {s}", .{ pub_name, table_name });
    defer allocator.free(create_pub_sql);
    try execSQL(setup_conn, create_pub_sql);

    const create_slot_sql = try test_helpers.formatSqlZ(allocator, "SELECT pg_create_logical_replication_slot('{s}', 'pgoutput')", .{slot_name});
    defer allocator.free(create_slot_sql);
    try execSQL(setup_conn, create_slot_sql);

    const lsn_result = c.PQexec(setup_conn, "SELECT pg_current_wal_lsn()");
    defer c.PQclear(lsn_result);
    const lsn_cstr = c.PQgetvalue(lsn_result, 0, 0);
    const start_lsn = try allocator.dupeZ(u8, std.mem.span(lsn_cstr));
    defer allocator.free(start_lsn);

    // 4000 bytes is comfortably above the ~2KB TOAST threshold.
    const insert_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (id, name, toast_field) VALUES (1, 'Alice', repeat('x', 4000))", .{table_name});
    defer allocator.free(insert_sql);
    try execSQL(setup_conn, insert_sql);

    // Update only name: toast_field is unchanged, so Postgres sends the 'u' marker for it.
    const update_sql = try test_helpers.formatSqlZ(allocator, "UPDATE {s} SET name = 'Bob' WHERE id = 1", .{table_name});
    defer allocator.free(update_sql);
    try execSQL(setup_conn, update_sql);

    try execSQL(setup_conn, "SELECT pg_switch_wal()");

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer source.deinit();

    try source.connect(conn_str, start_lsn);

    const batch = try source.receiveBatch(std.testing.io, allocator, 10, 0);
    defer {
        var mut_batch = batch;
        mut_batch.deinit();
    }

    std.log.info("Received batch with {} changes", .{batch.changes.len});

    var found_insert = false;
    var found_update = false;
    for (batch.changes) |change| {
        if (std.mem.eql(u8, change.op, "INSERT")) {
            found_insert = true;
            // On INSERT the full value is present, not the placeholder.
            const toast_val = fieldValue(change.data.insert, "toast_field");
            try testing.expect(toast_val != null);
            try testing.expectEqual(@as(usize, 4000), toast_val.?.len);
        } else if (std.mem.eql(u8, change.op, "UPDATE")) {
            found_update = true;
            const new_data = change.data.update.new;
            const name_val = fieldValue(new_data, "name");
            const toast_val = fieldValue(new_data, "toast_field");

            try testing.expect(name_val != null);
            try testing.expectEqualStrings("Bob", name_val.?);

            // Unchanged TOAST column stays in the payload as the placeholder.
            try testing.expect(toast_val != null);
            try testing.expectEqualStrings(constants.UNKNOWN_VALUE_PLACEHOLDER, toast_val.?);
        }
    }

    try testing.expect(found_insert);
    try testing.expect(found_update);

    try source.sendFeedback(std.testing.io, batch.last_lsn);

    std.log.info("TOAST E2E test passed!", .{});
}

test "Streaming source: DELETE operation E2E" {
    const allocator = testing.allocator;

    // Generate unique names for this test (timestamp + random to avoid collisions)
    var prng = std.Random.DefaultPrng.init(@intCast(test_helpers.nowMicros(std.testing.io)));
    const random_suffix = prng.random().int(u32);
    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "stream_delete_test_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(table_name);

    const slot_name = try std.fmt.allocPrint(allocator, "slot_delete_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(slot_name);

    const pub_name = try std.fmt.allocPrint(allocator, "pub_delete_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(pub_name);

    std.log.info("DELETE E2E test: table={s}, slot={s}, pub={s}", .{ table_name, slot_name, pub_name });

    // Setup connection
    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);

    // Cleanup defer - declared FIRST, executes LAST (after source.deinit)
    defer cleanupTestEnvironment(allocator, setup_conn, table_name, slot_name, pub_name);

    // Create table with REPLICA IDENTITY FULL to get old tuple in DELETE
    const create_table_sql = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, name TEXT)", .{table_name});
    defer allocator.free(create_table_sql);
    try execSQL(setup_conn, create_table_sql);

    // Set REPLICA IDENTITY FULL to get full row in DELETE messages
    const replica_identity_sql = try test_helpers.formatSqlZ(allocator, "ALTER TABLE {s} REPLICA IDENTITY FULL", .{table_name});
    defer allocator.free(replica_identity_sql);
    try execSQL(setup_conn, replica_identity_sql);

    // Create publication
    const create_pub_sql = try test_helpers.formatSqlZ(allocator, "CREATE PUBLICATION {s} FOR TABLE {s}", .{ pub_name, table_name });
    defer allocator.free(create_pub_sql);
    try execSQL(setup_conn, create_pub_sql);

    // Create replication slot
    const create_slot_sql = try test_helpers.formatSqlZ(allocator, "SELECT pg_create_logical_replication_slot('{s}', 'pgoutput')", .{slot_name});
    defer allocator.free(create_slot_sql);
    try execSQL(setup_conn, create_slot_sql);

    // Get current LSN
    const lsn_result = c.PQexec(setup_conn, "SELECT pg_current_wal_lsn()");
    defer c.PQclear(lsn_result);
    const lsn_cstr = c.PQgetvalue(lsn_result, 0, 0);
    const start_lsn = try allocator.dupeZ(u8, std.mem.span(lsn_cstr));
    defer allocator.free(start_lsn);

    // Insert initial row
    const insert_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (id, name) VALUES (1, 'Alice')", .{table_name});
    defer allocator.free(insert_sql);
    try execSQL(setup_conn, insert_sql);

    // Delete the row
    const delete_sql = try test_helpers.formatSqlZ(allocator, "DELETE FROM {s} WHERE id = 1", .{table_name});
    defer allocator.free(delete_sql);
    try execSQL(setup_conn, delete_sql);

    // Force WAL flush
    try execSQL(setup_conn, "SELECT pg_switch_wal()");

    // Connect streaming source
    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer source.deinit();

    try source.connect(conn_str, start_lsn);

    const batch = try source.receiveBatch(std.testing.io, allocator, 10, 0);
    defer {
        var mut_batch = batch;
        mut_batch.deinit();
    }

    std.log.info("Received batch with {} changes", .{batch.changes.len});

    // Find DELETE event
    var found_delete = false;
    for (batch.changes) |change| {
        std.log.info("Change: op={s}, resource={s}", .{ change.op, change.meta.resource });

        if (std.mem.eql(u8, change.op, "DELETE")) {
            found_delete = true;

            // Verify DELETE structure
            try testing.expect(change.data == .delete);

            const delete_data = change.data.delete;

            // Find name field in delete_data (should contain deleted row data)
            var deleted_name: ?[]const u8 = null;
            for (delete_data) |field| {
                if (std.mem.eql(u8, field.name, "name")) {
                    try testing.expect(field.value == .string);
                    deleted_name = field.value.string;
                }
            }

            // Verify deleted row had name = Alice
            try testing.expect(deleted_name != null);
            try testing.expectEqualStrings("Alice", deleted_name.?);
        }
    }

    try testing.expect(found_delete);

    // Send feedback
    try source.sendFeedback(std.testing.io, batch.last_lsn);

    std.log.info("DELETE E2E test passed!", .{});
}

test "Streaming source: Multiple batches with limit parameter" {
    const allocator = testing.allocator;

    // Generate unique names for this test (timestamp + random to avoid collisions)
    var prng = std.Random.DefaultPrng.init(@intCast(test_helpers.nowMicros(std.testing.io)));
    const random_suffix = prng.random().int(u32);
    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "stream_batch_test_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(table_name);

    const slot_name = try std.fmt.allocPrint(allocator, "slot_batch_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(slot_name);

    const pub_name = try std.fmt.allocPrint(allocator, "pub_batch_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(pub_name);

    std.log.info("Batching test: table={s}, slot={s}, pub={s}", .{ table_name, slot_name, pub_name });

    // Setup connection
    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);

    // Cleanup defer - declared FIRST, executes LAST (after source.deinit)
    defer cleanupTestEnvironment(allocator, setup_conn, table_name, slot_name, pub_name);

    // Create table
    const create_table_sql = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, value TEXT)", .{table_name});
    defer allocator.free(create_table_sql);
    try execSQL(setup_conn, create_table_sql);

    // Create publication
    const create_pub_sql = try test_helpers.formatSqlZ(allocator, "CREATE PUBLICATION {s} FOR TABLE {s}", .{ pub_name, table_name });
    defer allocator.free(create_pub_sql);
    try execSQL(setup_conn, create_pub_sql);

    // Create replication slot
    const create_slot_sql = try test_helpers.formatSqlZ(allocator, "SELECT pg_create_logical_replication_slot('{s}', 'pgoutput')", .{slot_name});
    defer allocator.free(create_slot_sql);
    try execSQL(setup_conn, create_slot_sql);

    // Get current LSN
    const lsn_result = c.PQexec(setup_conn, "SELECT pg_current_wal_lsn()");
    defer c.PQclear(lsn_result);
    const lsn_cstr = c.PQgetvalue(lsn_result, 0, 0);
    const start_lsn = try allocator.dupeZ(u8, std.mem.span(lsn_cstr));
    defer allocator.free(start_lsn);

    // Insert 500 rows
    const insert_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (value) SELECT 'row_' || i::text FROM generate_series(1, 500) AS i", .{table_name});
    defer allocator.free(insert_sql);
    try execSQL(setup_conn, insert_sql);

    // Force WAL flush
    try execSQL(setup_conn, "SELECT pg_switch_wal()");

    std.log.info("Inserted 500 rows, starting streaming...", .{});

    // Connect streaming source
    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer source.deinit();

    try source.connect(conn_str, start_lsn);

    var total_changes: usize = 0;
    var batch_count: usize = 0;
    var last_lsn: u64 = 0;

    while (total_changes < 500) {
        const batch = try source.receiveBatch(std.testing.io, allocator, 100, 0);
        defer {
            var mut_batch = batch;
            mut_batch.deinit();
        }

        if (batch.changes.len == 0) {
            std.log.warn("No more changes available, stopping (got {} total)", .{total_changes});
            break;
        }

        batch_count += 1;
        total_changes += batch.changes.len;
        last_lsn = batch.last_lsn;

        std.log.info("Batch {}: {} changes (total: {})", .{ batch_count, batch.changes.len, total_changes });

        // Send feedback after each batch
        try source.sendFeedback(std.testing.io, batch.last_lsn);
    }

    // Verify we got all 500 INSERT events
    try testing.expectEqual(@as(usize, 500), total_changes);
    try testing.expect(batch_count >= 5); // Should take at least 5 batches (500 / 100)

    std.log.info("Batching test passed: {} changes in {} batches", .{ total_changes, batch_count });
}

test "Streaming source: Timeout behavior with no data" {
    const allocator = testing.allocator;

    // Generate unique names for this test (timestamp + random to avoid collisions)
    var prng = std.Random.DefaultPrng.init(@intCast(test_helpers.nowMicros(std.testing.io)));
    const random_suffix = prng.random().int(u32);
    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "stream_timeout_test_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(table_name);

    const slot_name = try std.fmt.allocPrint(allocator, "slot_timeout_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(slot_name);

    const pub_name = try std.fmt.allocPrint(allocator, "pub_timeout_{d}_{d}", .{ timestamp, random_suffix });
    defer allocator.free(pub_name);

    std.log.info("Timeout test: table={s}, slot={s}, pub={s}", .{ table_name, slot_name, pub_name });

    // Setup connection
    const setup_conn = try createSetupConnection(allocator);
    defer c.PQfinish(setup_conn);

    // Cleanup defer - declared FIRST, executes LAST (after source.deinit)
    defer cleanupTestEnvironment(allocator, setup_conn, table_name, slot_name, pub_name);

    // Create table (empty, no data inserted)
    const create_table_sql = try test_helpers.formatSqlZ(allocator, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, value TEXT)", .{table_name});
    defer allocator.free(create_table_sql);
    try execSQL(setup_conn, create_table_sql);

    // Create publication
    const create_pub_sql = try test_helpers.formatSqlZ(allocator, "CREATE PUBLICATION {s} FOR TABLE {s}", .{ pub_name, table_name });
    defer allocator.free(create_pub_sql);
    try execSQL(setup_conn, create_pub_sql);

    // Create replication slot
    const create_slot_sql = try test_helpers.formatSqlZ(allocator, "SELECT pg_create_logical_replication_slot('{s}', 'pgoutput')", .{slot_name});
    defer allocator.free(create_slot_sql);
    try execSQL(setup_conn, create_slot_sql);

    // Get current LSN
    const lsn_result = c.PQexec(setup_conn, "SELECT pg_current_wal_lsn()");
    defer c.PQclear(lsn_result);
    const lsn_cstr = c.PQgetvalue(lsn_result, 0, 0);
    const start_lsn = try allocator.dupeZ(u8, std.mem.span(lsn_cstr));
    defer allocator.free(start_lsn);

    // Connect streaming source
    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer source.deinit();

    try source.connect(conn_str, start_lsn);

    std.log.info("Waiting for timeout with no data (1 second)...", .{});

    const start_time = test_helpers.nowMillis(std.testing.io);

    const batch = try source.receiveBatchWithWaitTime(std.testing.io, allocator, 10, 0, 1000);
    defer {
        var mut_batch = batch;
        mut_batch.deinit();
    }

    const elapsed = test_helpers.nowMillis(std.testing.io) - start_time;

    std.log.info("Timeout test: received {} changes in {}ms", .{ batch.changes.len, elapsed });

    // Verify: batch is empty (no data available)
    try testing.expectEqual(@as(usize, 0), batch.changes.len);

    // Verify: timeout was respected (should be ~1000ms, allow ±500ms tolerance)
    try testing.expect(elapsed >= 800);
    try testing.expect(elapsed <= 1500);

    std.log.info("Timeout test passed: empty batch returned gracefully after timeout", .{});
}
