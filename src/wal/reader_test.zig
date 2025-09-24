const std = @import("std");
const testing = std.testing;

const reader = @import("reader.zig");
const WalReader = reader.WalReader;
const WalEvent = reader.WalEvent;

test "WalReader.init" {
    const allocator = testing.allocator;
    const slot_name = "test_slot";

    const wal_reader = WalReader.init(allocator, slot_name);

    try testing.expectEqual(allocator, wal_reader.allocator);
    try testing.expectEqual(@as(?*anyopaque, null), @as(?*anyopaque, @ptrCast(wal_reader.connection)));
    try testing.expectEqualStrings(slot_name, wal_reader.slot_name);
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
