const std = @import("std");
const testing = std.testing;

const config = @import("config.zig");
const Config = config.Config;

test "Config.default" {
    const cfg = Config.default();

    try testing.expectEqualStrings("localhost", cfg.host);
    try testing.expectEqual(@as(u16, 5432), cfg.port);
    try testing.expectEqualStrings("zicdc_test", cfg.database);
    try testing.expectEqualStrings("postgres", cfg.user);
    try testing.expectEqualStrings("password", cfg.password);
    try testing.expectEqualStrings("zicdc_slot", cfg.slot_name);
}

test "Config.connectionString" {
    const allocator = testing.allocator;
    const cfg = Config.default();

    const conn_str = try cfg.connectionString(allocator);
    defer allocator.free(conn_str);

    // Check that all required connection parameters are present
    try testing.expect(std.mem.indexOf(u8, conn_str, "host=127.0.0.1") != null);
    try testing.expect(std.mem.indexOf(u8, conn_str, "port=5432") != null);
    try testing.expect(std.mem.indexOf(u8, conn_str, "dbname=zicdc_test") != null);
    try testing.expect(std.mem.indexOf(u8, conn_str, "user=postgres") != null);
    try testing.expect(std.mem.indexOf(u8, conn_str, "password=password") != null);
    try testing.expect(std.mem.indexOf(u8, conn_str, "replication=database") != null);
    try testing.expect(std.mem.indexOf(u8, conn_str, "gssencmode=disable") != null);
}