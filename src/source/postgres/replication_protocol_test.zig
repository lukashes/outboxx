const std = @import("std");
const testing = std.testing;

const replication = @import("replication_protocol.zig");
const ReplicationProtocol = replication.ReplicationProtocol;
const readU64BigEndian = replication.readU64BigEndian;
const readI64BigEndian = replication.readI64BigEndian;
const writeU64BigEndian = replication.writeU64BigEndian;
const writeI64BigEndian = replication.writeI64BigEndian;

const test_helpers = @import("test_helpers");
const getTestConnectionString = test_helpers.getTestConnectionString;

test "readU64BigEndian: basic value" {
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x23 };
    const result = readU64BigEndian(&bytes);
    try testing.expectEqual(@as(u64, 0x123), result);
}

test "readU64BigEndian: max value" {
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const result = readU64BigEndian(&bytes);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), result);
}

test "readU64BigEndian: zero" {
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const result = readU64BigEndian(&bytes);
    try testing.expectEqual(@as(u64, 0), result);
}

test "writeU64BigEndian: basic value" {
    var buffer: [8]u8 = undefined;
    writeU64BigEndian(&buffer, 0x123);

    const expected = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x23 };
    try testing.expectEqualSlices(u8, &expected, &buffer);
}

test "writeU64BigEndian: max value" {
    var buffer: [8]u8 = undefined;
    writeU64BigEndian(&buffer, std.math.maxInt(u64));

    const expected = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    try testing.expectEqualSlices(u8, &expected, &buffer);
}

test "writeU64BigEndian: zero" {
    var buffer: [8]u8 = undefined;
    writeU64BigEndian(&buffer, 0);

    const expected = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try testing.expectEqualSlices(u8, &expected, &buffer);
}

test "readI64BigEndian: positive value" {
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x23 };
    const result = readI64BigEndian(&bytes);
    try testing.expectEqual(@as(i64, 0x123), result);
}

test "readI64BigEndian: negative value" {
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const result = readI64BigEndian(&bytes);
    try testing.expectEqual(@as(i64, -1), result);
}

test "writeI64BigEndian: positive value" {
    var buffer: [8]u8 = undefined;
    writeI64BigEndian(&buffer, 0x123);

    const expected = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x23 };
    try testing.expectEqualSlices(u8, &expected, &buffer);
}

test "writeI64BigEndian: negative value" {
    var buffer: [8]u8 = undefined;
    writeI64BigEndian(&buffer, -1);

    const expected = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    try testing.expectEqualSlices(u8, &expected, &buffer);
}

test "round-trip u64 encoding" {
    const values = [_]u64{ 0, 1, 123, 0xDEADBEEF, std.math.maxInt(u64) };

    for (values) |value| {
        var buffer: [8]u8 = undefined;
        writeU64BigEndian(&buffer, value);
        const result = readU64BigEndian(&buffer);
        try testing.expectEqual(value, result);
    }
}

test "round-trip i64 encoding" {
    const values = [_]i64{ -1000, -1, 0, 1, 1000, std.math.maxInt(i64), std.math.minInt(i64) };

    for (values) |value| {
        var buffer: [8]u8 = undefined;
        writeI64BigEndian(&buffer, value);
        const result = readI64BigEndian(&buffer);
        try testing.expectEqual(value, result);
    }
}

test "ReplicationProtocol.init" {
    const allocator = testing.allocator;
    const slot_name = "test_repl_slot";
    const publication_name = "test_repl_pub";

    const protocol = ReplicationProtocol.init(allocator, slot_name, publication_name);

    try testing.expectEqual(allocator, protocol.allocator);
    try testing.expectEqual(@as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(protocol.connection)));
    try testing.expectEqualStrings(slot_name, protocol.slot_name);
    try testing.expectEqualStrings(publication_name, protocol.publication_name);
}

test "ReplicationProtocol: connect with replication mode" {
    const allocator = testing.allocator;

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    var protocol = ReplicationProtocol.init(allocator, "test_slot", "test_pub");
    defer protocol.deinit();

    try protocol.connect(conn_str);
    try testing.expect(protocol.connection != null);
}
