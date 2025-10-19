const std = @import("std");
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const WalReader = @import("wal_reader").WalReader;
const WalReaderError = @import("wal_reader").WalReaderError;
const WalParser = @import("wal_parser").WalParser;

/// Batch of changes from PostgreSQL (polling source)
pub const Batch = struct {
    /// Change events (flat list)
    changes: []ChangeEvent,

    /// LSN for feedback (last change in batch)
    last_lsn: u64,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Batch) void {
        for (self.changes) |*change| {
            change.deinit(self.allocator);
        }
        self.allocator.free(self.changes);
    }
};

/// PostgreSQL polling source adapter
/// Wraps WalReader + WalParser to match streaming source API
pub const PostgresPollingSource = struct {
    allocator: std.mem.Allocator,
    wal_reader: *WalReader,
    wal_parser: WalParser,

    const Self = @This();

    /// Initialize polling source
    pub fn init(allocator: std.mem.Allocator, wal_reader: *WalReader) Self {
        return Self{
            .allocator = allocator,
            .wal_reader = wal_reader,
            .wal_parser = WalParser.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.wal_parser.deinit();
    }

    /// Receive batch of changes from PostgreSQL
    /// limit: desired batch size (soft limit, may return more or less)
    pub fn receiveBatch(self: *Self, limit: usize) WalReaderError!Batch {
        // Poll PostgreSQL (limit is u32 in WalReader)
        const safe_limit = if (limit > std.math.maxInt(u32)) std.math.maxInt(u32) else @as(u32, @intCast(limit));
        var result = try self.wal_reader.peekChanges(safe_limit);
        defer result.deinit(self.allocator);

        // Parse text to ChangeEvents
        var changes = std.ArrayList(ChangeEvent).empty;
        errdefer {
            for (changes.items) |*change| {
                change.deinit(self.allocator);
            }
            changes.deinit(self.allocator);
        }

        for (result.events.items) |wal_event| {
            // Parse WAL event (text format from test_decoding)
            const change_opt = try self.wal_parser.parse(wal_event.data, "postgres");
            if (change_opt) |change_event| {
                try changes.append(self.allocator, change_event);
            }
        }

        // Convert LSN from string to u64 (map parsing errors to InvalidData)
        const last_lsn = if (result.last_lsn) |lsn_str|
            lsnToU64(lsn_str) catch |err| {
                std.log.warn("Failed to parse LSN '{s}': {}", .{ lsn_str, err });
                return WalReaderError.InvalidData;
            }
        else
            0;

        return .{
            .changes = try changes.toOwnedSlice(self.allocator),
            .last_lsn = last_lsn,
            .allocator = self.allocator,
        };
    }

    /// Send LSN feedback to PostgreSQL (confirm processing)
    pub fn sendFeedback(self: *Self, lsn: u64) WalReaderError!void {
        // Convert u64 LSN to string format for WalReader
        const lsn_str = u64ToLsn(self.allocator, lsn) catch {
            return WalReaderError.OutOfMemory;
        };
        defer self.allocator.free(lsn_str);

        try self.wal_reader.advanceSlot(lsn_str);
    }
};

/// Parse text LSN "16/B374D848" -> 0x16B374D848
fn lsnToU64(lsn_str: []const u8) !u64 {
    // Find slash separator
    const slash_pos = std.mem.indexOfScalar(u8, lsn_str, '/') orelse return error.InvalidLsn;

    // Parse high part (before slash)
    const high_str = lsn_str[0..slash_pos];
    const high = try std.fmt.parseInt(u32, high_str, 16);

    // Parse low part (after slash)
    const low_str = lsn_str[slash_pos + 1 ..];
    const low = try std.fmt.parseInt(u32, low_str, 16);

    // Combine: (high << 32) | low
    return (@as(u64, high) << 32) | @as(u64, low);
}

/// Format binary LSN 0x16B374D848 -> "16/B374D848"
fn u64ToLsn(allocator: std.mem.Allocator, lsn: u64) ![]const u8 {
    const high: u32 = @intCast((lsn >> 32) & 0xFFFFFFFF);
    const low: u32 = @intCast(lsn & 0xFFFFFFFF);
    return try std.fmt.allocPrint(allocator, "{X}/{X}", .{ high, low });
}

// Unit tests
const testing = std.testing;

test "lsnToU64: parse valid LSN" {
    const lsn_str = "16/B374D848";
    const result = try lsnToU64(lsn_str);
    try testing.expectEqual(@as(u64, 0x16B374D848), result);
}

test "lsnToU64: parse zero LSN" {
    const lsn_str = "0/0";
    const result = try lsnToU64(lsn_str);
    try testing.expectEqual(@as(u64, 0), result);
}

test "lsnToU64: parse max LSN" {
    const lsn_str = "FFFFFFFF/FFFFFFFF";
    const result = try lsnToU64(lsn_str);
    try testing.expectEqual(@as(u64, 0xFFFFFFFF_FFFFFFFF), result);
}

test "lsnToU64: invalid format - no slash" {
    const lsn_str = "16B374D848";
    const result = lsnToU64(lsn_str);
    try testing.expectError(error.InvalidLsn, result);
}

test "u64ToLsn: format valid LSN" {
    const lsn: u64 = 0x16B374D848;
    const result = try u64ToLsn(testing.allocator, lsn);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("16/B374D848", result);
}

test "u64ToLsn: format zero LSN" {
    const lsn: u64 = 0;
    const result = try u64ToLsn(testing.allocator, lsn);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("0/0", result);
}

test "u64ToLsn: format max LSN" {
    const lsn: u64 = 0xFFFFFFFF_FFFFFFFF;
    const result = try u64ToLsn(testing.allocator, lsn);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("FFFFFFFF/FFFFFFFF", result);
}
