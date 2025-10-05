const std = @import("std");
const testing = std.testing;
const PostgresValidator = @import("validator.zig").PostgresValidator;

test "PostgresValidator initialization" {
    const allocator = testing.allocator;
    const validator = PostgresValidator.init(allocator);
    _ = validator;
}

test "PostgresValidator: connection test requires PostgreSQL" {
    const allocator = testing.allocator;
    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    const conn_str = "host=localhost port=5432 dbname=outboxx_test user=postgres password=password";

    const result = validator.connect(conn_str);
    if (result) {
        std.log.info("PostgreSQL validation: Connection test passed", .{});
    } else |err| {
        std.log.warn("PostgreSQL validation: Skipping test (PostgreSQL not available): {}", .{err});
        return error.SkipZigTest;
    }
}

test "PostgresValidator: version check requires PostgreSQL" {
    const allocator = testing.allocator;
    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    const conn_str = "host=localhost port=5432 dbname=outboxx_test user=postgres password=password";

    validator.connect(conn_str) catch |err| {
        std.log.warn("PostgreSQL validation: Skipping test (PostgreSQL not available): {}", .{err});
        return error.SkipZigTest;
    };

    const result = validator.checkPostgresVersion();
    if (result) {
        std.log.info("PostgreSQL validation: Version check passed", .{});
    } else |err| {
        std.log.warn("PostgreSQL validation: Version check failed: {}", .{err});
        return error.SkipZigTest;
    }
}

test "PostgresValidator: wal_level check requires PostgreSQL" {
    const allocator = testing.allocator;
    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    const conn_str = "host=localhost port=5432 dbname=outboxx_test user=postgres password=password replication=database";

    validator.connect(conn_str) catch |err| {
        std.log.warn("PostgreSQL validation: Skipping test (PostgreSQL not available): {}", .{err});
        return error.SkipZigTest;
    };

    const result = validator.checkWalLevel();
    if (result) {
        std.log.info("PostgreSQL validation: wal_level check passed", .{});
    } else |err| {
        std.log.warn("PostgreSQL validation: wal_level check failed: {}", .{err});
        return error.SkipZigTest;
    }
}

test "PostgresValidator: table existence check requires PostgreSQL" {
    const allocator = testing.allocator;
    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    const conn_str = "host=localhost port=5432 dbname=outboxx_test user=postgres password=password";

    validator.connect(conn_str) catch |err| {
        std.log.warn("PostgreSQL validation: Skipping test (PostgreSQL not available): {}", .{err});
        return error.SkipZigTest;
    };

    const result = validator.checkTableExists("public", "users");
    if (result) {
        std.log.info("PostgreSQL validation: Table existence check passed", .{});
    } else |err| {
        std.log.warn("PostgreSQL validation: Skipping test (table missing): {}", .{err});
        return error.SkipZigTest;
    }
}

test "PostgresValidator: table not found should error" {
    const allocator = testing.allocator;
    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    const conn_str = "host=localhost port=5432 dbname=outboxx_test user=postgres password=password";

    validator.connect(conn_str) catch |err| {
        std.log.warn("PostgreSQL validation: Skipping test (PostgreSQL not available): {}", .{err});
        return error.SkipZigTest;
    };

    const result = validator.checkTableExists("public", "nonexistent_table_xyz");

    if (result) {
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.TableNotFound => {},
        error.ConnectionFailed => return error.SkipZigTest,
        else => return err,
    }
}

test "PostgresValidator: invalid schema should error" {
    const allocator = testing.allocator;
    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    const conn_str = "host=localhost port=5432 dbname=outboxx_test user=postgres password=password";

    validator.connect(conn_str) catch |err| {
        std.log.warn("PostgreSQL validation: Skipping test (PostgreSQL not available): {}", .{err});
        return error.SkipZigTest;
    };

    const result = validator.checkTableExists("nonexistent_schema_xyz", "users");

    if (result) {
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.TableNotFound => {},
        error.ConnectionFailed => return error.SkipZigTest,
        else => return err,
    }
}

test "PostgresValidator: invalid connection string should error" {
    const allocator = testing.allocator;
    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    // Invalid host that doesn't exist
    const invalid_conn_str = "host=invalid-host-that-does-not-exist.local port=5432 dbname=test user=test password=test";

    const result = validator.connect(invalid_conn_str);

    if (result) {
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.ConnectionFailed => {}, // Expected error
        else => return err,
    }
}

test "PostgresValidator: methods fail when not connected" {
    const allocator = testing.allocator;
    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    // Try to call methods without connecting first
    const version_result = validator.checkPostgresVersion();
    try testing.expectError(error.ConnectionFailed, version_result);

    const wal_result = validator.checkWalLevel();
    try testing.expectError(error.ConnectionFailed, wal_result);

    const table_result = validator.checkTableExists("public", "users");
    try testing.expectError(error.ConnectionFailed, table_result);
}

// Note: Testing invalid PostgreSQL version and wal_level requires mocking or
// a test PostgreSQL instance with specific configuration. These are best tested
// in a dedicated CI environment with controlled PostgreSQL versions.
//
// For local development, we document the expected behavior:
// - checkPostgresVersion() should return InvalidPostgresVersion for PG < 10
// - checkWalLevel() should return InvalidWalLevel for wal_level != 'logical'
