const std = @import("std");
const testing = std.testing;

const source_mod = @import("source.zig");
const PostgresSource = source_mod.PostgresSource;
const Batch = source_mod.Batch;

test "PostgresSource: init and deinit" {
    const allocator = testing.allocator;

    var source = PostgresSource.init(allocator, "test_slot", "test_pub");
    defer source.deinit();

    try testing.expectEqual(@as(u64, 0), source.last_lsn);
}

test "Batch: deinit with empty changes" {
    const allocator = testing.allocator;

    const changes = try allocator.alloc(@import("domain").ChangeEvent, 0);

    var batch = Batch{
        .changes = changes,
        .last_lsn = 12345,
        .allocator = allocator,
    };
    defer batch.deinit();

    try testing.expectEqual(@as(u64, 12345), batch.last_lsn);
    try testing.expectEqual(@as(usize, 0), batch.changes.len);
}
