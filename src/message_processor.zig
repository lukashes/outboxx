const std = @import("std");

pub const ChangeOperation = enum {
    INSERT,
    UPDATE,
    DELETE,
    UNKNOWN,
};

pub const ChangeMessage = struct {
    operation: ChangeOperation,
    table_name: []const u8,
    schema_name: []const u8,
    data: []const u8,
    old_data: ?[]const u8, // For UPDATE and DELETE operations
    timestamp: i64,

    const Self = @This();

    pub fn toJson(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        // Simple JSON formatting for now
        if (self.old_data) |old| {
            return std.fmt.allocPrint(allocator,
                "{{\"operation\":\"{s}\",\"table\":\"{s}\",\"schema\":\"{s}\",\"data\":\"{s}\",\"old_data\":\"{s}\",\"timestamp\":{}}}",
                .{ @tagName(self.operation), self.table_name, self.schema_name, self.data, old, self.timestamp }
            );
        } else {
            return std.fmt.allocPrint(allocator,
                "{{\"operation\":\"{s}\",\"table\":\"{s}\",\"schema\":\"{s}\",\"data\":\"{s}\",\"timestamp\":{}}}",
                .{ @tagName(self.operation), self.table_name, self.schema_name, self.data, self.timestamp }
            );
        }
    }

    pub fn getTopicName(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        // Topic naming: schema.table (e.g., "public.users")
        return std.fmt.allocPrint(allocator, "{s}.{s}", .{ self.schema_name, self.table_name });
    }

    pub fn getPartitionKey(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        // Use table name as partition key for now
        // In a real CDC system, you'd extract primary key values
        return allocator.dupe(u8, self.table_name);
    }
};

pub const MessageProcessor = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn parseWalMessage(self: *Self, wal_data: []const u8) !?ChangeMessage {
        // Parse test_decoding output format
        // Example: "table public.users: INSERT: id[integer]:1 email[character varying]:'alice@example.com' name[character varying]:'Alice Johnson'"

        if (wal_data.len == 0) return null;

        // Skip non-table messages (like "BEGIN", "COMMIT")
        if (!std.mem.startsWith(u8, wal_data, "table ")) return null;

        // Extract operation type
        const operation = blk: {
            if (std.mem.indexOf(u8, wal_data, ": INSERT:")) |_| break :blk ChangeOperation.INSERT;
            if (std.mem.indexOf(u8, wal_data, ": UPDATE:")) |_| break :blk ChangeOperation.UPDATE;
            if (std.mem.indexOf(u8, wal_data, ": DELETE:")) |_| break :blk ChangeOperation.DELETE;
            break :blk ChangeOperation.UNKNOWN;
        };

        // Extract table name (format: "table schema.table_name:")
        const table_start = "table ".len;
        const colon_pos = std.mem.indexOf(u8, wal_data[table_start..], ":") orelse return null;
        const full_table_name = wal_data[table_start..table_start + colon_pos];

        // Split schema.table
        const dot_pos = std.mem.indexOf(u8, full_table_name, ".") orelse return null;
        const schema_name = try self.allocator.dupe(u8, full_table_name[0..dot_pos]);
        const table_name = try self.allocator.dupe(u8, full_table_name[dot_pos + 1..]);

        // Extract data part
        const operation_str = switch (operation) {
            .INSERT => ": INSERT: ",
            .UPDATE => ": UPDATE: ",
            .DELETE => ": DELETE: ",
            .UNKNOWN => return null,
        };

        const data_start_pos = std.mem.indexOf(u8, wal_data, operation_str) orelse return null;
        const data_start = data_start_pos + operation_str.len;

        var data: []const u8 = "";
        const old_data: ?[]const u8 = null;

        if (operation == .UPDATE) {
            // For UPDATE, we need to parse both old and new data
            // Format: "old-key[type]:old-value new-key[type]:new-value"
            // For simplicity, we'll take everything as data for now
            data = try self.allocator.dupe(u8, wal_data[data_start..]);
        } else {
            data = try self.allocator.dupe(u8, wal_data[data_start..]);
        }

        const timestamp = std.time.timestamp();

        return ChangeMessage{
            .operation = operation,
            .table_name = table_name,
            .schema_name = schema_name,
            .data = data,
            .old_data = old_data,
            .timestamp = timestamp,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Cleanup would go here if needed
    }
};

// Unit tests
test "MessageProcessor parse INSERT" {
    const testing = std.testing;

    // Use testing allocator with leak detection
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    var processor = MessageProcessor.init(allocator);
    defer processor.deinit();

    const wal_data = "table public.users: INSERT: id[integer]:1 email[character varying]:'alice@example.com'";

    const message = try processor.parseWalMessage(wal_data);
    defer if (message) |msg| {
        allocator.free(msg.schema_name);
        allocator.free(msg.table_name);
        allocator.free(msg.data);
    };

    try testing.expect(message != null);
    if (message) |msg| {
        try testing.expectEqual(ChangeOperation.INSERT, msg.operation);
        try testing.expectEqualStrings("public", msg.schema_name);
        try testing.expectEqualStrings("users", msg.table_name);
        try testing.expectEqualStrings("id[integer]:1 email[character varying]:'alice@example.com'", msg.data);
    }
}

test "MessageProcessor skip non-table messages" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var processor = MessageProcessor.init(allocator);
    defer processor.deinit();

    const begin_msg = "BEGIN 760";
    const commit_msg = "COMMIT 760";

    const begin_result = try processor.parseWalMessage(begin_msg);
    const commit_result = try processor.parseWalMessage(commit_msg);

    try testing.expect(begin_result == null);
    try testing.expect(commit_result == null);
}