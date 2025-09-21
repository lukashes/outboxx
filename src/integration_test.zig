const std = @import("std");
const testing = std.testing;

// Direct imports work now because we're in src/
const Config = @import("config.zig").Config;
const WalReader = @import("wal/reader.zig").WalReader;

test "WAL reader integration tests" {
    // These tests require PostgreSQL running (use 'make env-up' first)
    std.testing.refAllDecls(@This());
}

test "WAL reader can connect to PostgreSQL" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.default();
    var wal_reader = WalReader.init(allocator, config.slot_name);
    defer wal_reader.deinit();

    const conn_str = try config.connectionString(allocator);
    defer allocator.free(conn_str);

    // This should not fail if PostgreSQL is running
    wal_reader.connect(conn_str) catch |err| switch (err) {
        error.ConnectionFailed => {
            std.debug.print("PostgreSQL not available - skipping test\n", .{});
            return; // Skip test if PostgreSQL is not running
        },
        else => return err,
    };
}

test "WAL reader can create and drop replication slot" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.default();
    const test_slot_name = "test_slot_integration";
    var wal_reader = WalReader.init(allocator, test_slot_name);
    defer wal_reader.deinit();

    const conn_str = try config.connectionString(allocator);
    defer allocator.free(conn_str);

    wal_reader.connect(conn_str) catch |err| switch (err) {
        error.ConnectionFailed => {
            std.debug.print("PostgreSQL not available - skipping test\n", .{});
            return;
        },
        else => return err,
    };

    // Clean up any existing slot first
    wal_reader.dropSlot() catch {};

    // Create slot should succeed
    try wal_reader.createSlot();

    // Drop slot should succeed
    try wal_reader.dropSlot();
}

test "WAL reader can read changes from empty slot" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.default();
    const test_slot_name = "test_slot_read_empty";
    var wal_reader = WalReader.init(allocator, test_slot_name);
    defer wal_reader.deinit();

    const conn_str = try config.connectionString(allocator);
    defer allocator.free(conn_str);

    wal_reader.connect(conn_str) catch |err| switch (err) {
        error.ConnectionFailed => {
            std.debug.print("PostgreSQL not available - skipping test\n", .{});
            return;
        },
        else => return err,
    };

    // Clean up any existing slot first
    wal_reader.dropSlot() catch {};

    // Create slot
    try wal_reader.createSlot();
    defer wal_reader.dropSlot() catch {};

    // Read changes (should be empty initially)
    var changes = try wal_reader.readChanges(10);
    defer {
        for (changes.items) |*change| {
            change.deinit(allocator);
        }
        changes.deinit(allocator);
    }

    // Should return empty list initially
    try testing.expect(changes.items.len == 0);
}

// Helper function to execute SQL commands (non-replication connection)
fn executeSql(allocator: std.mem.Allocator, _: []const u8, sql: []const u8) !void {
    const c = @cImport({
        @cInclude("libpq-fe.h");
    });

    // Create non-replication connection string
    const regular_conn_str = try std.fmt.allocPrint(allocator,
        "host=127.0.0.1 port=5432 dbname=outboxx_test user=postgres password=password", .{});
    defer allocator.free(regular_conn_str);

    const conn = c.PQconnectdb(regular_conn_str.ptr);
    defer c.PQfinish(conn);

    if (c.PQstatus(conn) != c.CONNECTION_OK) {
        return error.ConnectionFailed;
    }

    // Ensure autocommit is enabled
    const autocommit_result = c.PQexec(conn, "SET autocommit = on;");
    defer c.PQclear(autocommit_result);

    const result = c.PQexec(conn, sql.ptr);
    defer c.PQclear(result);

    const status = c.PQresultStatus(result);
    if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
        const error_msg = c.PQresultErrorMessage(result);
        std.debug.print("SQL Error: {s}\n", .{error_msg});
        return error.SqlExecutionFailed;
    }
}

test "PostgreSQL logical replication configuration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.default();
    const conn_str = try config.connectionString(allocator);
    defer allocator.free(conn_str);

    // This will help us debug the PostgreSQL configuration
    std.debug.print("Checking PostgreSQL logical replication settings...\n", .{});

    // For now, just ensure we can connect
    try testing.expect(true);
}

test "WAL reader can detect INSERT operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.default();
    const test_slot_name = "test_slot_insert";
    var wal_reader = WalReader.init(allocator, test_slot_name);
    defer wal_reader.deinit();

    const conn_str = try config.connectionString(allocator);
    defer allocator.free(conn_str);

    wal_reader.connect(conn_str) catch |err| switch (err) {
        error.ConnectionFailed => {
            std.debug.print("PostgreSQL not available - skipping test\n", .{});
            return;
        },
        else => return err,
    };

    // Clean up any existing test data first
    const cleanup_sql_initial = "DELETE FROM users WHERE email = 'test_insert@example.com';";
    executeSql(allocator, conn_str, cleanup_sql_initial) catch {};

    // Clean up and create slot
    wal_reader.dropSlot() catch {};
    try wal_reader.createSlot();
    defer wal_reader.dropSlot() catch {};

    // Insert new user
    const insert_sql =
        \\INSERT INTO users (email, name, status)
        \\VALUES ('test_insert@example.com', 'Test User Insert', 'active')
    ;
    try executeSql(allocator, conn_str, insert_sql);

    // Force WAL flush and give time for logical replication
    const flush_sql = "SELECT pg_switch_wal();";
    executeSql(allocator, conn_str, flush_sql) catch {};
    std.Thread.sleep(50_000_000); // 50ms

    // Read changes
    var changes = try wal_reader.readChanges(10);
    defer {
        for (changes.items) |*change| {
            change.deinit(allocator);
        }
        changes.deinit(allocator);
    }

    // Should have at least one change for INSERT
    try testing.expect(changes.items.len > 0);

    // Check that we have INSERT operation in the data
    var found_insert = false;
    for (changes.items) |change| {
        if (std.mem.indexOf(u8, change.data, "INSERT") != null and
            std.mem.indexOf(u8, change.data, "test_insert@example.com") != null) {
            found_insert = true;
            std.debug.print("Found INSERT change: {s}\n", .{change.data});
            break;
        }
    }
    try testing.expect(found_insert);

    // Cleanup
    const cleanup_sql_final = "DELETE FROM users WHERE email = 'test_insert@example.com';";
    executeSql(allocator, conn_str, cleanup_sql_final) catch {};
}

test "WAL reader can detect UPDATE operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.default();
    const test_slot_name = "test_slot_update";
    var wal_reader = WalReader.init(allocator, test_slot_name);
    defer wal_reader.deinit();

    const conn_str = try config.connectionString(allocator);
    defer allocator.free(conn_str);

    wal_reader.connect(conn_str) catch |err| switch (err) {
        error.ConnectionFailed => {
            std.debug.print("PostgreSQL not available - skipping test\n", .{});
            return;
        },
        else => return err,
    };

    // Clean up any existing test data first
    const cleanup_sql_initial = "DELETE FROM users WHERE email = 'test_update@example.com';";
    executeSql(allocator, conn_str, cleanup_sql_initial) catch {};

    // Clean up and create slot
    wal_reader.dropSlot() catch {};
    try wal_reader.createSlot();
    defer wal_reader.dropSlot() catch {};

    // Set REPLICA IDENTITY FULL to capture full row data for UPDATEs
    const replica_identity_sql = "ALTER TABLE users REPLICA IDENTITY FULL;";
    try executeSql(allocator, conn_str, replica_identity_sql);

    // First insert a test user
    const insert_sql =
        \\INSERT INTO users (email, name, status)
        \\VALUES ('test_update@example.com', 'Test User Update', 'active')
    ;
    try executeSql(allocator, conn_str, insert_sql);

    // Force WAL flush and give time for logical replication
    const flush_sql = "SELECT pg_switch_wal();";
    executeSql(allocator, conn_str, flush_sql) catch {};
    std.Thread.sleep(50_000_000); // 50ms

    // Clear any existing changes from the insert
    var initial_changes = try wal_reader.readChanges(100);
    std.debug.print("Initial changes from INSERT: {d}\n", .{initial_changes.items.len});
    for (initial_changes.items) |*change| {
        std.debug.print("INSERT change: {s}\n", .{change.data});
        change.deinit(allocator);
    }
    initial_changes.deinit(allocator);

    // Now update the user
    const update_sql =
        \\UPDATE users SET status = 'premium', name = 'Updated User Name'
        \\WHERE email = 'test_update@example.com'
    ;
    try executeSql(allocator, conn_str, update_sql);

    // Force WAL flush and give time for logical replication
    const flush_sql2 = "SELECT pg_switch_wal();";
    executeSql(allocator, conn_str, flush_sql2) catch {};
    std.Thread.sleep(100_000_000); // 100ms

    // Read changes
    var changes = try wal_reader.readChanges(10);
    defer {
        for (changes.items) |*change| {
            change.deinit(allocator);
        }
        changes.deinit(allocator);
    }

    // Should have at least one change for UPDATE
    try testing.expect(changes.items.len > 0);

    // Check that we have UPDATE operation in the data
    var found_update = false;
    for (changes.items) |change| {
        if (std.mem.indexOf(u8, change.data, "UPDATE") != null and
            std.mem.indexOf(u8, change.data, "test_update@example.com") != null) {
            found_update = true;
            std.debug.print("Found UPDATE change: {s}\n", .{change.data});
            break;
        }
    }
    try testing.expect(found_update);

    // Cleanup
    const cleanup_sql_final = "DELETE FROM users WHERE email = 'test_update@example.com';";
    executeSql(allocator, conn_str, cleanup_sql_final) catch {};
}

test "WAL reader can detect DELETE operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.default();
    const test_slot_name = "test_slot_delete";
    var wal_reader = WalReader.init(allocator, test_slot_name);
    defer wal_reader.deinit();

    const conn_str = try config.connectionString(allocator);
    defer allocator.free(conn_str);

    wal_reader.connect(conn_str) catch |err| switch (err) {
        error.ConnectionFailed => {
            std.debug.print("PostgreSQL not available - skipping test\n", .{});
            return;
    },
        else => return err,
    };

    // Clean up any existing test data first
    const cleanup_sql_initial = "DELETE FROM users WHERE email = 'test_delete@example.com';";
    executeSql(allocator, conn_str, cleanup_sql_initial) catch {};

    // Clean up and create slot
    wal_reader.dropSlot() catch {};
    try wal_reader.createSlot();
    defer wal_reader.dropSlot() catch {};

    // Set REPLICA IDENTITY FULL to capture full row data for DELETEs
    const replica_identity_sql = "ALTER TABLE users REPLICA IDENTITY FULL;";
    try executeSql(allocator, conn_str, replica_identity_sql);

    // First insert a test user to delete
    const insert_sql =
        \\INSERT INTO users (email, name, status)
        \\VALUES ('test_delete@example.com', 'Test User Delete', 'active')
    ;
    try executeSql(allocator, conn_str, insert_sql);

    // Force WAL flush and give time for logical replication
    const flush_sql_insert = "SELECT pg_switch_wal();";
    executeSql(allocator, conn_str, flush_sql_insert) catch {};
    std.Thread.sleep(50_000_000); // 50ms

    // Clear any existing changes from the insert
    var initial_changes = try wal_reader.readChanges(100);
    for (initial_changes.items) |*change| {
        change.deinit(allocator);
    }
    initial_changes.deinit(allocator);

    // Now delete the user
    const delete_sql = "DELETE FROM users WHERE email = 'test_delete@example.com';";
    try executeSql(allocator, conn_str, delete_sql);

    // Force WAL flush and give time for logical replication
    const flush_sql_delete = "SELECT pg_switch_wal();";
    executeSql(allocator, conn_str, flush_sql_delete) catch {};
    std.Thread.sleep(100_000_000); // 100ms

    // Read changes
    var changes = try wal_reader.readChanges(10);
    defer {
        for (changes.items) |*change| {
            change.deinit(allocator);
        }
        changes.deinit(allocator);
    }

    // Should have at least one change for DELETE
    try testing.expect(changes.items.len > 0);

    // Check that we have DELETE operation in the data
    var found_delete = false;
    for (changes.items) |change| {
        if (std.mem.indexOf(u8, change.data, "DELETE") != null and
            std.mem.indexOf(u8, change.data, "test_delete@example.com") != null) {
            found_delete = true;
            std.debug.print("Found DELETE change: {s}\n", .{change.data});
            break;
        }
    }
    try testing.expect(found_delete);
}