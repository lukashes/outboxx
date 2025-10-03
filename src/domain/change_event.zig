const std = @import("std");

// Change operation types
pub const ChangeOperation = enum {
    INSERT,
    UPDATE,
    DELETE,
    UNKNOWN,
};

// Field value using std.json.Value for flexibility
pub const FieldValue = std.json.Value;

// Helper functions to create field values
pub const FieldValueHelpers = struct {
    pub fn integer(val: i64) std.json.Value {
        return std.json.Value{ .integer = val };
    }

    pub fn text(allocator: std.mem.Allocator, str: []const u8) !std.json.Value {
        return std.json.Value{ .string = try allocator.dupe(u8, str) };
    }

    pub fn boolean(val: bool) std.json.Value {
        return std.json.Value{ .bool = val };
    }

    pub fn null_value() std.json.Value {
        return std.json.Value.null;
    }
};

// Field data structure (name + value pair)
pub const FieldData = struct {
    name: []const u8,
    value: std.json.Value,
};

// Row data is a slice of fields
pub const RowData = []FieldData;

// Helper functions for working with RowData
pub const RowDataHelpers = struct {
    pub fn createBuilder(allocator: std.mem.Allocator) std.ArrayList(FieldData) {
        _ = allocator;
        return std.ArrayList(FieldData){};
    }

    pub fn put(builder: *std.ArrayList(FieldData), allocator: std.mem.Allocator, field_name: []const u8, value: std.json.Value) !void {
        const owned_name = try allocator.dupe(u8, field_name);
        const field_data = FieldData{
            .name = owned_name,
            .value = value,
        };
        try builder.append(allocator, field_data);
    }

    pub fn finalize(builder: *std.ArrayList(FieldData), allocator: std.mem.Allocator) !RowData {
        return try builder.toOwnedSlice(allocator);
    }

    pub fn deinit(row: *RowData, allocator: std.mem.Allocator) void {
        for (row.*) |field| {
            allocator.free(field.name);
            if (field.value == .string) {
                allocator.free(field.value.string);
            }
        }
        allocator.free(row.*);
    }

    pub fn hasField(row: RowData, field_name: []const u8) bool {
        for (row) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                return true;
            }
        }
        return false;
    }

    pub fn getField(row: RowData, field_name: []const u8) ?std.json.Value {
        for (row) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                return field.value;
            }
        }
        return null;
    }
};

// Data section for different operations
pub const DataSection = union(enum) {
    insert: RowData,
    delete: RowData,
    update: struct {
        new: RowData,
        old: RowData,
    },
};

// Source metadata
pub const Metadata = struct {
    source: []const u8, // "postgres", "mysql", etc.
    resource: []const u8, // table/collection name
    schema: []const u8, // database schema
    timestamp: i64, // when the change occurred
    lsn: ?[]const u8, // Log sequence number (optional, source-specific)
};

// Main domain model - clean change event
pub const ChangeEvent = struct {
    op: []const u8, // operation as string
    data: DataSection,
    meta: Metadata,

    const Self = @This();

    pub fn init(operation: ChangeOperation, metadata: Metadata) Self {
        return Self{
            .op = @tagName(operation),
            .data = undefined, // will be set via setXxxData methods
            .meta = metadata,
        };
    }

    pub fn setInsertData(self: *Self, data: RowData) void {
        self.data = DataSection{ .insert = data };
    }

    pub fn setDeleteData(self: *Self, data: RowData) void {
        self.data = DataSection{ .delete = data };
    }

    pub fn setUpdateData(self: *Self, new_data: RowData, old_data: RowData) void {
        self.data = DataSection{ .update = .{ .new = new_data, .old = old_data } };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.data) {
            .insert => |*data| {
                var mut_data = data.*;
                RowDataHelpers.deinit(&mut_data, allocator);
            },
            .delete => |*data| {
                var mut_data = data.*;
                RowDataHelpers.deinit(&mut_data, allocator);
            },
            .update => |*update_data| {
                var mut_new = update_data.new;
                var mut_old = update_data.old;
                RowDataHelpers.deinit(&mut_new, allocator);
                RowDataHelpers.deinit(&mut_old, allocator);
            },
        }
    }

    /// Get partition key value from the event data
    /// For INSERT and DELETE: uses the primary data row
    /// For UPDATE: uses the new data row
    /// Returns null if field not found
    pub fn getPartitionKeyValue(self: *const Self, allocator: std.mem.Allocator, field_name: []const u8) !?[]const u8 {
        const row = switch (self.data) {
            .insert => |data| data,
            .delete => |data| data,
            .update => |update_data| update_data.new,
        };

        const field_value = RowDataHelpers.getField(row, field_name) orelse return null;

        // Convert field value to string for Kafka partition key
        return switch (field_value) {
            .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
            .string => |s| try allocator.dupe(u8, s),
            .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
            .null => try allocator.dupe(u8, "null"),
            else => null, // For complex types, return null
        };
    }
};

// Tests
test "ChangeEvent creation and memory management" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = Metadata{
        .source = "postgres",
        .resource = "users",
        .schema = "public",
        .timestamp = 1234567890,
        .lsn = null,
    };

    var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);
    defer event.deinit(allocator);

    var builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&builder, allocator, "id", FieldValueHelpers.integer(1));
    try RowDataHelpers.put(&builder, allocator, "name", try FieldValueHelpers.text(allocator, "Alice"));
    const row = try RowDataHelpers.finalize(&builder, allocator);
    event.setInsertData(row);

    try testing.expectEqualStrings("INSERT", event.op);
    try testing.expectEqualStrings("postgres", event.meta.source);
    try testing.expectEqualStrings("users", event.meta.resource);
}

test "RowDataHelpers field access" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    var builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&builder, allocator, "id", FieldValueHelpers.integer(42));
    try RowDataHelpers.put(&builder, allocator, "active", FieldValueHelpers.boolean(true));
    var row = try RowDataHelpers.finalize(&builder, allocator);
    defer RowDataHelpers.deinit(&row, allocator);

    try testing.expect(RowDataHelpers.hasField(row, "id"));
    try testing.expect(RowDataHelpers.hasField(row, "active"));
    try testing.expect(!RowDataHelpers.hasField(row, "nonexistent"));

    const id_value = RowDataHelpers.getField(row, "id").?;
    try testing.expectEqual(@as(i64, 42), id_value.integer);

    const active_value = RowDataHelpers.getField(row, "active").?;
    try testing.expectEqual(true, active_value.bool);
}

test "UPDATE event with old and new data" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = Metadata{
        .source = "postgres",
        .resource = "users",
        .schema = "public",
        .timestamp = 1234567890,
        .lsn = null,
    };

    var event = ChangeEvent.init(ChangeOperation.UPDATE, metadata);
    defer event.deinit(allocator);

    // Old data
    var old_builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&old_builder, allocator, "status", try FieldValueHelpers.text(allocator, "pending"));
    const old_row = try RowDataHelpers.finalize(&old_builder, allocator);

    // New data
    var new_builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&new_builder, allocator, "status", try FieldValueHelpers.text(allocator, "active"));
    const new_row = try RowDataHelpers.finalize(&new_builder, allocator);

    event.setUpdateData(new_row, old_row);

    try testing.expectEqualStrings("UPDATE", event.op);

    switch (event.data) {
        .update => |update_data| {
            const old_status = RowDataHelpers.getField(update_data.old, "status").?;
            const new_status = RowDataHelpers.getField(update_data.new, "status").?;
            try testing.expectEqualStrings("pending", old_status.string);
            try testing.expectEqualStrings("active", new_status.string);
        },
        else => try testing.expect(false),
    }
}

test "getPartitionKeyValue extracts field values" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = Metadata{
        .source = "postgres",
        .resource = "users",
        .schema = "public",
        .timestamp = 1234567890,
        .lsn = null,
    };

    // Test with INSERT (integer id)
    {
        var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);
        defer event.deinit(allocator);

        var builder = RowDataHelpers.createBuilder(allocator);
        try RowDataHelpers.put(&builder, allocator, "id", FieldValueHelpers.integer(42));
        try RowDataHelpers.put(&builder, allocator, "email", try FieldValueHelpers.text(allocator, "test@example.com"));
        const row = try RowDataHelpers.finalize(&builder, allocator);
        event.setInsertData(row);

        // Get integer partition key
        const key1 = try event.getPartitionKeyValue(allocator, "id");
        try testing.expect(key1 != null);
        defer allocator.free(key1.?);
        try testing.expectEqualStrings("42", key1.?);

        // Get string partition key
        const key2 = try event.getPartitionKeyValue(allocator, "email");
        try testing.expect(key2 != null);
        defer allocator.free(key2.?);
        try testing.expectEqualStrings("test@example.com", key2.?);

        // Non-existent field
        const key3 = try event.getPartitionKeyValue(allocator, "nonexistent");
        try testing.expect(key3 == null);
    }

    // Test with UPDATE (uses new data)
    {
        var event = ChangeEvent.init(ChangeOperation.UPDATE, metadata);
        defer event.deinit(allocator);

        var old_builder = RowDataHelpers.createBuilder(allocator);
        try RowDataHelpers.put(&old_builder, allocator, "id", FieldValueHelpers.integer(99));
        const old_row = try RowDataHelpers.finalize(&old_builder, allocator);

        var new_builder = RowDataHelpers.createBuilder(allocator);
        try RowDataHelpers.put(&new_builder, allocator, "id", FieldValueHelpers.integer(42));
        const new_row = try RowDataHelpers.finalize(&new_builder, allocator);

        event.setUpdateData(new_row, old_row);

        // Should get value from new data, not old
        const key = try event.getPartitionKeyValue(allocator, "id");
        try testing.expect(key != null);
        defer allocator.free(key.?);
        try testing.expectEqualStrings("42", key.?);
    }
}
