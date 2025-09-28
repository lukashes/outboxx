const std = @import("std");
const json = std.json;

pub const ChangeOperation = enum {
    INSERT,
    UPDATE,
    DELETE,
    UNKNOWN,
};

// Simplified field value using std.json.Value for easy serialization
pub const FieldValue = std.json.Value;

// Helper function to create field values
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

// Simple table row using array of field data - no allocators!
pub const TableRow = RowData;

// Helper functions for working with TableRow (RowData)
pub const TableRowHelpers = struct {
    // Create a builder for constructing RowData
    pub fn createBuilder(allocator: std.mem.Allocator) std.ArrayList(FieldData) {
        _ = allocator;
        return std.ArrayList(FieldData){};
    }

    // Add field to builder
    pub fn put(builder: *std.ArrayList(FieldData), allocator: std.mem.Allocator, field_name: []const u8, value: std.json.Value) !void {
        const owned_name = try allocator.dupe(u8, field_name);
        const field_data = FieldData{
            .name = owned_name,
            .value = value,
        };
        try builder.append(allocator, field_data);
    }

    // Convert builder to RowData
    pub fn finalize(builder: *std.ArrayList(FieldData), allocator: std.mem.Allocator) !RowData {
        return try builder.toOwnedSlice(allocator);
    }

    // Clean up RowData
    pub fn deinit(row: *RowData, allocator: std.mem.Allocator) void {
        for (row.*) |field| {
            // Free owned string keys
            allocator.free(field.name);
            // Free string values if they were allocated
            if (field.value == .string) {
                allocator.free(field.value.string);
            }
        }
        allocator.free(row.*);
    }

    // Helper functions for testing RowData
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

// Source metadata - now JSON serializable
pub const SourceMetadata = struct {
    source: []const u8, // "postgres", "mysql"
    resource: []const u8, // table name from config
    schema: []const u8, // database schema
    timestamp: i64, // when the change occurred
    lsn: ?[]const u8, // PostgreSQL LSN (if available)

};

// Clean data structures for JSON serialization - no allocators!
pub const FieldData = struct {
    name: []const u8,
    value: std.json.Value,
};

pub const RowData = []FieldData;

// Data section structure for different operations - pure data
pub const DataSection = union(enum) {
    insert: RowData, // new data
    delete: RowData, // old data
    update: struct {
        new: RowData,
        old: RowData,
    },

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        switch (self) {
            .insert => |data| {
                try jws.beginObject();
                for (data) |field| {
                    try jws.objectField(field.name);
                    try jws.write(field.value);
                }
                try jws.endObject();
            },
            .delete => |data| {
                try jws.beginObject();
                for (data) |field| {
                    try jws.objectField(field.name);
                    try jws.write(field.value);
                }
                try jws.endObject();
            },
            .update => |update_data| {
                try jws.beginObject();
                try jws.objectField("new");
                try jws.beginObject();
                for (update_data.new) |field| {
                    try jws.objectField(field.name);
                    try jws.write(field.value);
                }
                try jws.endObject();
                try jws.objectField("old");
                try jws.beginObject();
                for (update_data.old) |field| {
                    try jws.objectField(field.name);
                    try jws.write(field.value);
                }
                try jws.endObject();
                try jws.endObject();
            },
        }
    }
};

// Simplified structured change message - directly JSON serializable
pub const StructuredChangeMessage = struct {
    op: []const u8, // operation as string
    data: DataSection,
    meta: SourceMetadata,

    const Self = @This();

    pub fn init(operation: ChangeOperation, metadata: SourceMetadata) Self {
        return Self{
            .op = @tagName(operation),
            .data = undefined, // will be set later
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
        // Cleanup data section
        switch (self.data) {
            .insert => |*data| {
                var mut_data = data.*;
                TableRowHelpers.deinit(&mut_data, allocator);
            },
            .delete => |*data| {
                var mut_data = data.*;
                TableRowHelpers.deinit(&mut_data, allocator);
            },
            .update => |*update_data| {
                var mut_new = update_data.new;
                var mut_old = update_data.old;
                TableRowHelpers.deinit(&mut_new, allocator);
                TableRowHelpers.deinit(&mut_old, allocator);
            },
        }
        // metadata fields are managed by caller
    }

    // JSON serialization using std.json.stringify - now possible without allocator field!
    pub fn toJson(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self.*, .{});
    }

    // For compatibility with existing code
    pub fn getTopicName(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}.{s}", .{ self.meta.schema, self.meta.resource });
    }

    pub fn getPartitionKey(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, self.meta.resource);
    }
};

// Parser for WAL fields into typed values
pub const WalFieldParser = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    // Parses field string like "id[integer]:1 email[character varying]:'alice@example.com'"
    // into TableRow with typed values
    pub fn parseFields(self: *Self, fields_data: []const u8) !RowData {
        var builder = TableRowHelpers.createBuilder(self.allocator);
        errdefer builder.deinit(self.allocator);

        // Simple strategy: find "name[type]:value" patterns considering that value may contain spaces in quotes
        var i: usize = 0;
        while (i < fields_data.len) {
            // Skip spaces
            while (i < fields_data.len and fields_data[i] == ' ') {
                i += 1;
            }
            if (i >= fields_data.len) break;

            // Find start of next field (find next "[")
            const field_start = i;
            const bracket_pos = std.mem.indexOfPos(u8, fields_data, i, "[") orelse break;

            // Field name
            const field_name = std.mem.trim(u8, fields_data[field_start..bracket_pos], " \t");

            // Find "]"
            const bracket_end = std.mem.indexOfPos(u8, fields_data, bracket_pos + 1, "]") orelse break;
            const field_type = fields_data[bracket_pos + 1 .. bracket_end];

            // Find ":"
            const colon_pos = std.mem.indexOfPos(u8, fields_data, bracket_end + 1, ":") orelse break;
            if (colon_pos != bracket_end + 1) break; // Should be right after ]

            // Find value (until next field or end of string)
            const value_start = colon_pos + 1;
            var value_end = fields_data.len;

            // Find end of value - look for next pattern "name["
            var next_field_start = value_start + 1;
            while (next_field_start < fields_data.len) {
                if (fields_data[next_field_start] == ' ') {
                    // Check if there's a pattern "name[" after space
                    var temp_pos = next_field_start + 1;
                    while (temp_pos < fields_data.len and fields_data[temp_pos] == ' ') {
                        temp_pos += 1;
                    }
                    if (temp_pos < fields_data.len) {
                        const next_bracket = std.mem.indexOfPos(u8, fields_data, temp_pos, "[");
                        if (next_bracket != null) {
                            // Check that between temp_pos and next_bracket only letters/digits/_
                            var is_field_name = true;
                            for (fields_data[temp_pos..next_bracket.?]) |c| {
                                if (!std.ascii.isAlphanumeric(c) and c != '_') {
                                    is_field_name = false;
                                    break;
                                }
                            }
                            if (is_field_name) {
                                value_end = next_field_start;
                                break;
                            }
                        }
                    }
                }
                next_field_start += 1;
            }

            const field_value = std.mem.trim(u8, fields_data[value_start..value_end], " \t");

            // Parse field
            const typed_value = try self.parseTypedValue(field_type, field_value);
            try TableRowHelpers.put(&builder, self.allocator, field_name, typed_value);

            // Continue from end of current value
            i = value_end;
        }

        return try TableRowHelpers.finalize(&builder, self.allocator);
    }

    fn parseTypedValue(self: *Self, field_type: []const u8, value_str: []const u8) !std.json.Value {
        // Handle NULL values
        if (std.mem.eql(u8, value_str, "null") or value_str.len == 0) {
            return FieldValueHelpers.null_value();
        }

        // Determine type by PostgreSQL types
        if (std.mem.startsWith(u8, field_type, "integer") or
            std.mem.startsWith(u8, field_type, "bigint") or
            std.mem.startsWith(u8, field_type, "smallint") or
            std.mem.startsWith(u8, field_type, "numeric"))
        {
            const parsed_int = std.fmt.parseInt(i64, value_str, 10) catch 0;
            return FieldValueHelpers.integer(parsed_int);
        }

        if (std.mem.startsWith(u8, field_type, "boolean")) {
            const is_true = std.mem.eql(u8, value_str, "true") or std.mem.eql(u8, value_str, "t");
            return FieldValueHelpers.boolean(is_true);
        }

        // All other types as strings (text, varchar, char, etc.)
        var text_value = value_str;

        // Remove quotes if present
        if (text_value.len >= 2 and text_value[0] == '\'' and text_value[text_value.len - 1] == '\'') {
            text_value = text_value[1 .. text_value.len - 1];
        }

        return try FieldValueHelpers.text(self.allocator, text_value);
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // Cleanup if needed
    }
};

// New structured WAL message parser
pub const StructuredWalMessageParser = struct {
    allocator: std.mem.Allocator,
    field_parser: WalFieldParser,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .field_parser = WalFieldParser.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.field_parser.deinit();
    }

    // Parses WAL message into StructuredChangeMessage
    pub fn parseWalMessage(self: *Self, wal_data: []const u8, source_name: []const u8, resource_name: []const u8) !?StructuredChangeMessage {
        if (wal_data.len == 0) return null;

        // Skip non-table messages
        if (!std.mem.startsWith(u8, wal_data, "table ")) return null;

        // Extract operation type
        const operation = blk: {
            if (std.mem.indexOf(u8, wal_data, ": INSERT:")) |_| break :blk ChangeOperation.INSERT;
            if (std.mem.indexOf(u8, wal_data, ": UPDATE:")) |_| break :blk ChangeOperation.UPDATE;
            if (std.mem.indexOf(u8, wal_data, ": DELETE:")) |_| break :blk ChangeOperation.DELETE;
            break :blk ChangeOperation.UNKNOWN;
        };

        if (operation == .UNKNOWN) return null;

        // Extract table name
        const table_start = "table ".len;
        const colon_pos = std.mem.indexOf(u8, wal_data[table_start..], ":") orelse return null;
        const full_table_name = wal_data[table_start .. table_start + colon_pos];

        const dot_pos = std.mem.indexOf(u8, full_table_name, ".") orelse return null;
        const schema_name = full_table_name[0..dot_pos];
        const table_name = full_table_name[dot_pos + 1 ..];

        // Check that this is the needed table
        if (!std.mem.eql(u8, table_name, resource_name)) {
            return null; // Not the right table
        }

        // Create metadata
        const metadata = SourceMetadata{
            .source = source_name,
            .resource = resource_name,
            .schema = schema_name,
            .timestamp = std.time.timestamp(),
            .lsn = null, // TODO: extract LSN if available
        };

        // Create message
        var message = StructuredChangeMessage.init(operation, metadata);

        // Extract data part
        const operation_str = switch (operation) {
            .INSERT => ": INSERT: ",
            .UPDATE => ": UPDATE: ",
            .DELETE => ": DELETE: ",
            .UNKNOWN => unreachable,
        };

        const data_start_pos = std.mem.indexOf(u8, wal_data, operation_str) orelse return null;
        const data_start = data_start_pos + operation_str.len;
        const fields_data = wal_data[data_start..];

        // Parse fields depending on operation
        switch (operation) {
            .INSERT => {
                const row = try self.field_parser.parseFields(fields_data);
                message.setInsertData(row);
            },
            .DELETE => {
                const row = try self.field_parser.parseFields(fields_data);
                message.setDeleteData(row);
            },
            .UPDATE => {
                // UPDATE format: "old-key: <old fields> new-tuple: <new fields>"
                if (std.mem.indexOf(u8, fields_data, "new-tuple:")) |new_tuple_pos| {
                    // Has both old and new data
                    const old_data_end = new_tuple_pos;
                    const new_data_start = new_tuple_pos + "new-tuple: ".len;

                    // Parse old data (skip "old-key: ")
                    const old_start = if (std.mem.indexOf(u8, fields_data, "old-key: ")) |pos| pos + "old-key: ".len else 0;
                    const old_fields_data = std.mem.trim(u8, fields_data[old_start..old_data_end], " \t");

                    // Parse new data
                    const new_fields_data = std.mem.trim(u8, fields_data[new_data_start..], " \t");

                    var old_row: RowData = &[_]FieldData{};
                    var new_row: RowData = &[_]FieldData{};

                    if (old_fields_data.len > 0) {
                        old_row = try self.field_parser.parseFields(old_fields_data);
                    }
                    if (new_fields_data.len > 0) {
                        new_row = try self.field_parser.parseFields(new_fields_data);
                    }

                    message.setUpdateData(new_row, old_row);
                } else {
                    // Only new data (simplified format)
                    const new_row = try self.field_parser.parseFields(fields_data);
                    const old_row: RowData = &[_]FieldData{};
                    message.setUpdateData(new_row, old_row);
                }
            },
            .UNKNOWN => unreachable,
        }

        return message;
    }
};

// Tests for new structured types

test "WalFieldParser parse simple fields" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    var parser = WalFieldParser.init(allocator);
    defer parser.deinit();

    const fields_data = "id[integer]:1 email[character varying]:'alice@example.com' active[boolean]:true";

    var row = try parser.parseFields(fields_data);
    defer TableRowHelpers.deinit(&row, allocator);

    // Check that fields were parsed correctly
    try testing.expect(TableRowHelpers.hasField(row, "id"));
    try testing.expect(TableRowHelpers.hasField(row, "email"));
    try testing.expect(TableRowHelpers.hasField(row, "active"));

    const id_value = TableRowHelpers.getField(row, "id").?;
    try testing.expectEqual(@as(i64, 1), id_value.integer);

    const email_value = TableRowHelpers.getField(row, "email").?;
    try testing.expectEqualStrings("alice@example.com", email_value.string);

    const active_value = TableRowHelpers.getField(row, "active").?;
    try testing.expectEqual(true, active_value.bool);
}

test "StructuredChangeMessage JSON serialization INSERT" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = SourceMetadata{
        .source = "postgres",
        .resource = "users",
        .schema = "public",
        .timestamp = 1234567890,
        .lsn = null,
    };

    var message = StructuredChangeMessage.init(ChangeOperation.INSERT, metadata);
    defer message.deinit(allocator);

    // Add some data
    var builder = TableRowHelpers.createBuilder(allocator);
    try TableRowHelpers.put(&builder, allocator, "id", FieldValueHelpers.integer(1));
    try TableRowHelpers.put(&builder, allocator, "name", try FieldValueHelpers.text(allocator, "Alice"));
    try TableRowHelpers.put(&builder, allocator, "active", FieldValueHelpers.boolean(true));
    const row = try TableRowHelpers.finalize(&builder, allocator);
    message.setInsertData(row);

    const json_output = try message.toJson(allocator);
    defer allocator.free(json_output);

    // Check JSON structure
    try testing.expect(std.mem.indexOf(u8, json_output, "\"op\":\"INSERT\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"data\":{") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"meta\":{") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"source\":\"postgres\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"resource\":\"users\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"schema\":\"public\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"timestamp\":1234567890") != null);

    // Check data fields
    try testing.expect(std.mem.indexOf(u8, json_output, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"name\":\"Alice\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"active\":true") != null);
}

test "StructuredChangeMessage JSON serialization UPDATE" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = SourceMetadata{
        .source = "postgres",
        .resource = "users",
        .schema = "public",
        .timestamp = 1234567890,
        .lsn = null,
    };

    var message = StructuredChangeMessage.init(ChangeOperation.UPDATE, metadata);
    defer message.deinit(allocator);

    // Add old data
    var old_builder = TableRowHelpers.createBuilder(allocator);
    try TableRowHelpers.put(&old_builder, allocator, "id", FieldValueHelpers.integer(1));
    try TableRowHelpers.put(&old_builder, allocator, "name", try FieldValueHelpers.text(allocator, "Old Name"));
    const old_row = try TableRowHelpers.finalize(&old_builder, allocator);

    // Add new data
    var new_builder = TableRowHelpers.createBuilder(allocator);
    try TableRowHelpers.put(&new_builder, allocator, "id", FieldValueHelpers.integer(1));
    try TableRowHelpers.put(&new_builder, allocator, "name", try FieldValueHelpers.text(allocator, "New Name"));
    const new_row = try TableRowHelpers.finalize(&new_builder, allocator);

    message.setUpdateData(new_row, old_row);

    const json_output = try message.toJson(allocator);
    defer allocator.free(json_output);

    // Check UPDATE-specific JSON structure
    try testing.expect(std.mem.indexOf(u8, json_output, "\"op\":\"UPDATE\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"data\":{\"new\":") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"old\":") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"name\":\"New Name\"") != null);
    try testing.expect(std.mem.indexOf(u8, json_output, "\"name\":\"Old Name\"") != null);
}

test "StructuredWalMessageParser parse INSERT" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    var parser = StructuredWalMessageParser.init(allocator);
    defer parser.deinit();

    const wal_data = "table public.users: INSERT: id[integer]:1 email[character varying]:'alice@example.com' active[boolean]:true";

    var message = try parser.parseWalMessage(wal_data, "postgres", "users");
    if (message) |*msg| {
        defer msg.deinit(allocator);

        try testing.expectEqualStrings("INSERT", msg.op);
        try testing.expectEqualStrings("postgres", msg.meta.source);
        try testing.expectEqualStrings("users", msg.meta.resource);
        try testing.expectEqualStrings("public", msg.meta.schema);

        // Check that data was parsed correctly
        switch (msg.data) {
            .insert => |data| {
                try testing.expect(TableRowHelpers.hasField(data, "id"));
                try testing.expect(TableRowHelpers.hasField(data, "email"));
                try testing.expect(TableRowHelpers.hasField(data, "active"));

                const id_value = TableRowHelpers.getField(data, "id").?;
                try testing.expectEqual(@as(i64, 1), id_value.integer);
            },
            else => try testing.expect(false), // Should be insert
        }

        // Test JSON generation
        const json_output = try msg.toJson(allocator);
        defer allocator.free(json_output);

        try testing.expect(std.mem.indexOf(u8, json_output, "\"op\":\"INSERT\"") != null);
        try testing.expect(std.mem.indexOf(u8, json_output, "\"id\":1") != null);
        try testing.expect(std.mem.indexOf(u8, json_output, "\"email\":\"alice@example.com\"") != null);
    } else {
        try testing.expect(false); // Should have parsed successfully
    }
}

test "FieldValue memory management" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    // Test string value creation and access
    const original_value = try FieldValueHelpers.text(allocator, "test string");
    defer allocator.free(original_value.string);

    try testing.expectEqualStrings("test string", original_value.string);
}

test "JSON output validation - INSERT message" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = SourceMetadata{
        .source = "postgres",
        .resource = "users",
        .schema = "public",
        .timestamp = 1234567890,
        .lsn = null,
    };

    var message = StructuredChangeMessage.init(ChangeOperation.INSERT, metadata);
    defer message.deinit(allocator);

    var builder = TableRowHelpers.createBuilder(allocator);
    try TableRowHelpers.put(&builder, allocator, "id", FieldValueHelpers.integer(42));
    try TableRowHelpers.put(&builder, allocator, "name", try FieldValueHelpers.text(allocator, "Test User"));
    const row = try TableRowHelpers.finalize(&builder, allocator);
    message.setInsertData(row);

    const json_output = try message.toJson(allocator);
    defer allocator.free(json_output);

    // Validate that generated JSON is parseable
    const is_valid = try std.json.validate(allocator, json_output);
    try testing.expect(is_valid);

    // Verify structure can be parsed back
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_output, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expect(root.contains("op"));
    try testing.expect(root.contains("data"));
    try testing.expect(root.contains("meta"));

    const op = root.get("op").?.string;
    try testing.expectEqualStrings("INSERT", op);
}

test "JSON output validation - UPDATE message" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = SourceMetadata{
        .source = "postgres",
        .resource = "users",
        .schema = "public",
        .timestamp = 1234567890,
        .lsn = null,
    };

    var message = StructuredChangeMessage.init(ChangeOperation.UPDATE, metadata);
    defer message.deinit(allocator);

    var old_builder = TableRowHelpers.createBuilder(allocator);
    try TableRowHelpers.put(&old_builder, allocator, "id", FieldValueHelpers.integer(1));
    try TableRowHelpers.put(&old_builder, allocator, "status", try FieldValueHelpers.text(allocator, "pending"));
    const old_row = try TableRowHelpers.finalize(&old_builder, allocator);

    var new_builder = TableRowHelpers.createBuilder(allocator);
    try TableRowHelpers.put(&new_builder, allocator, "id", FieldValueHelpers.integer(1));
    try TableRowHelpers.put(&new_builder, allocator, "status", try FieldValueHelpers.text(allocator, "active"));
    const new_row = try TableRowHelpers.finalize(&new_builder, allocator);

    message.setUpdateData(new_row, old_row);

    const json_output = try message.toJson(allocator);
    defer allocator.free(json_output);

    // Validate that generated JSON is parseable
    const is_valid = try std.json.validate(allocator, json_output);
    try testing.expect(is_valid);

    // Verify structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_output, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const data = root.get("data").?.object;
    try testing.expect(data.contains("new"));
    try testing.expect(data.contains("old"));

    const new_data = data.get("new").?.object;
    const old_data = data.get("old").?.object;
    try testing.expectEqualStrings("active", new_data.get("status").?.string);
    try testing.expectEqualStrings("pending", old_data.get("status").?.string);
}

test "JSON output validation - DELETE message" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = SourceMetadata{
        .source = "postgres",
        .resource = "users",
        .schema = "public",
        .timestamp = 1234567890,
        .lsn = null,
    };

    var message = StructuredChangeMessage.init(ChangeOperation.DELETE, metadata);
    defer message.deinit(allocator);

    var builder = TableRowHelpers.createBuilder(allocator);
    try TableRowHelpers.put(&builder, allocator, "id", FieldValueHelpers.integer(99));
    const row = try TableRowHelpers.finalize(&builder, allocator);
    message.setDeleteData(row);

    const json_output = try message.toJson(allocator);
    defer allocator.free(json_output);

    // Validate that generated JSON is parseable
    const is_valid = try std.json.validate(allocator, json_output);
    try testing.expect(is_valid);

    // Verify structure
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_output, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("DELETE", root.get("op").?.string);

    const data = root.get("data").?.object;
    try testing.expectEqual(@as(i64, 99), data.get("id").?.integer);
}
