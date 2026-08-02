const std = @import("std");
const domain = @import("../domain/change_event.zig");
const ChangeEvent = domain.ChangeEvent;
const DataSection = domain.DataSection;
const FieldData = domain.FieldData;
const RowData = domain.RowData;

/// Serializes a ChangeEvent to JSON bytes.
pub const JsonSerializer = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    /// Serialize a ChangeEvent to JSON bytes; caller owns the result.
    pub fn serialize(self: *const Self, event: ChangeEvent, allocator: std.mem.Allocator) ![]u8 {
        _ = self;

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();

        const writer = &output.writer;

        try writer.writeAll("{\"op\":");
        try encodeString(event.op, writer);
        try writer.writeAll(",\"data\":");

        try serializeDataSection(event.data, writer);

        try writer.writeAll(",\"meta\":{\"source\":");
        try encodeString(event.meta.source, writer);
        try writer.writeAll(",\"resource\":");
        try encodeString(event.meta.resource, writer);
        try writer.writeAll(",\"schema\":");
        try encodeString(event.meta.schema, writer);
        try writer.writeAll(",\"timestamp\":");
        try writer.print("{d}", .{event.meta.timestamp});

        if (event.meta.lsn) |lsn| {
            try writer.writeAll(",\"lsn\":");
            try encodeString(lsn, writer);
        } else {
            try writer.writeAll(",\"lsn\":null");
        }

        try writer.writeAll("}}");

        return output.toOwnedSlice();
    }

    // Write a JSON string (surrounding quotes plus RFC 8259 escaping, including
    // control chars below 0x20) via the stdlib encoder. Used for every string in
    // the output, so column names and metadata are escaped like values.
    fn encodeString(s: []const u8, writer: *std.Io.Writer) !void {
        try std.json.Stringify.encodeJsonString(s, .{}, writer);
    }

    fn serializeDataSection(data: DataSection, writer: anytype) !void {
        switch (data) {
            .insert => |row| {
                try serializeRow(row, writer);
            },
            .delete => |row| {
                try serializeRow(row, writer);
            },
            .update => |update_data| {
                // Serialize only new data (current state after update)
                try serializeRow(update_data.new, writer);
            },
        }
    }

    fn serializeRow(row: RowData, writer: anytype) !void {
        try writer.writeAll("{");

        for (row, 0..) |field, i| {
            if (i > 0) {
                try writer.writeAll(",");
            }

            try encodeString(field.name, writer);
            try writer.writeAll(":");

            try serializeValue(field.value, writer);
        }

        try writer.writeAll("}");
    }

    fn serializeValue(value: std.json.Value, writer: anytype) !void {
        switch (value) {
            .null => try writer.writeAll("null"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| {
                // Defence in depth: NaN/Infinity are not valid JSON numbers. The
                // Postgres type mapper already maps them to strings, so a non-finite
                // float here means one slipped in from elsewhere. Fail loudly instead
                // of emitting invalid JSON.
                if (!std.math.isFinite(f)) return error.NonFiniteFloat;
                try writer.print("{d}", .{f});
            },
            .number_string => |ns| try writer.writeAll(ns),
            .string => |s| try encodeString(s, writer),
            .array => |arr| {
                try writer.writeAll("[");
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(",");
                    try serializeValue(item, writer);
                }
                try writer.writeAll("]");
            },
            .object => |obj| {
                try writer.writeAll("{");
                var iter = obj.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try encodeString(entry.key_ptr.*, writer);
                    try writer.writeAll(":");
                    try serializeValue(entry.value_ptr.*, writer);
                }
                try writer.writeAll("}");
            },
        }
    }
};

// Tests
const ChangeOperation = domain.ChangeOperation;
const Metadata = domain.Metadata;
const RowDataHelpers = domain.RowDataHelpers;
const FieldValueHelpers = domain.FieldValueHelpers;

test "JsonSerializer serialize INSERT event" {
    const testing = std.testing;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = Metadata{
        .source = try allocator.dupe(u8, "postgres"),
        .resource = try allocator.dupe(u8, "users"),
        .schema = try allocator.dupe(u8, "public"),
        .timestamp = 1234567890,
        .lsn = null,
    };

    var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);
    defer event.deinit(allocator);

    var builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&builder, allocator, "id", FieldValueHelpers.integer(1));
    try RowDataHelpers.put(&builder, allocator, "name", try FieldValueHelpers.text(allocator, "Alice"));
    try RowDataHelpers.put(&builder, allocator, "active", FieldValueHelpers.boolean(true));
    const row = try RowDataHelpers.finalize(&builder, allocator);
    event.setInsertData(row);

    const serializer = JsonSerializer.init();
    const json_output = try serializer.serialize(event, allocator);
    defer allocator.free(json_output);

    // Validate JSON structure
    try testing.expect(std.mem.find(u8, json_output, "\"op\":\"INSERT\"") != null);
    try testing.expect(std.mem.find(u8, json_output, "\"data\":{") != null);
    try testing.expect(std.mem.find(u8, json_output, "\"meta\":{") != null);
    try testing.expect(std.mem.find(u8, json_output, "\"source\":\"postgres\"") != null);
    try testing.expect(std.mem.find(u8, json_output, "\"resource\":\"users\"") != null);
    try testing.expect(std.mem.find(u8, json_output, "\"id\":1") != null);
    try testing.expect(std.mem.find(u8, json_output, "\"name\":\"Alice\"") != null);
    try testing.expect(std.mem.find(u8, json_output, "\"active\":true") != null);
}

test "JsonSerializer serialize UPDATE event" {
    const testing = std.testing;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = Metadata{
        .source = try allocator.dupe(u8, "postgres"),
        .resource = try allocator.dupe(u8, "users"),
        .schema = try allocator.dupe(u8, "public"),
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

    const serializer = JsonSerializer.init();
    const json_output = try serializer.serialize(event, allocator);
    defer allocator.free(json_output);

    // Validate UPDATE structure - now simplified (only new data)
    try testing.expect(std.mem.find(u8, json_output, "\"op\":\"UPDATE\"") != null);
    try testing.expect(std.mem.find(u8, json_output, "\"data\":{\"status\":\"active\"}") != null);
    // Old data is NOT in JSON output (only in domain model)
    try testing.expect(std.mem.find(u8, json_output, "pending") == null);
}

test "JsonSerializer rejects non-finite float" {
    const testing = std.testing;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = Metadata{
        .source = try allocator.dupe(u8, "postgres"),
        .resource = try allocator.dupe(u8, "users"),
        .schema = try allocator.dupe(u8, "public"),
        .timestamp = 1234567890,
        .lsn = null,
    };

    var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);
    defer event.deinit(allocator);

    var builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&builder, allocator, "ratio", FieldValueHelpers.float(std.math.inf(f64)));
    const row = try RowDataHelpers.finalize(&builder, allocator);
    event.setInsertData(row);

    const serializer = JsonSerializer.init();
    try testing.expectError(error.NonFiniteFloat, serializer.serialize(event, allocator));
}

test "JsonSerializer validate JSON output is parseable" {
    const testing = std.testing;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = Metadata{
        .source = try allocator.dupe(u8, "postgres"),
        .resource = try allocator.dupe(u8, "users"),
        .schema = try allocator.dupe(u8, "public"),
        .timestamp = 1234567890,
        .lsn = null,
    };

    var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);
    defer event.deinit(allocator);

    var builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&builder, allocator, "id", FieldValueHelpers.integer(42));
    const row = try RowDataHelpers.finalize(&builder, allocator);
    event.setInsertData(row);

    const serializer = JsonSerializer.init();
    const json_output = try serializer.serialize(event, allocator);
    defer allocator.free(json_output);

    // Parse JSON back to validate it's correct
    const is_valid = try std.json.validate(allocator, json_output);
    try testing.expect(is_valid);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_output, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expect(root.contains("op"));
    try testing.expect(root.contains("data"));
    try testing.expect(root.contains("meta"));
}

test "JsonSerializer string escaping" {
    const testing = std.testing;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = Metadata{
        .source = try allocator.dupe(u8, "postgres"),
        .resource = try allocator.dupe(u8, "users"),
        .schema = try allocator.dupe(u8, "public"),
        .timestamp = 1234567890,
        .lsn = null,
    };

    var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);
    defer event.deinit(allocator);

    var builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&builder, allocator, "text", try FieldValueHelpers.text(allocator, "Line 1\nLine 2\t\"quoted\""));
    const row = try RowDataHelpers.finalize(&builder, allocator);
    event.setInsertData(row);

    const serializer = JsonSerializer.init();
    const json_output = try serializer.serialize(event, allocator);
    defer allocator.free(json_output);

    // Validate escaping
    try testing.expect(std.mem.find(u8, json_output, "\\n") != null);
    try testing.expect(std.mem.find(u8, json_output, "\\t") != null);
    try testing.expect(std.mem.find(u8, json_output, "\\\"") != null);

    // Validate JSON is still parseable
    const is_valid = try std.json.validate(allocator, json_output);
    try testing.expect(is_valid);
}

test "JsonSerializer escapes control characters and quoted field names" {
    const testing = std.testing;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    const metadata = Metadata{
        .source = try allocator.dupe(u8, "postgres"),
        .resource = try allocator.dupe(u8, "users"),
        .schema = try allocator.dupe(u8, "public"),
        .timestamp = 1234567890,
        .lsn = null,
    };

    var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);
    defer event.deinit(allocator);

    // A legal Postgres column name can contain a quote; a text value can carry
    // control bytes (NUL, backspace, form feed, vertical tab) that RFC 8259
    // requires to be escaped. Both broke the output before.
    const field_name = "a\"b";
    const field_value = "x\x00\x08\x0C\x0By";

    var builder = RowDataHelpers.createBuilder(allocator);
    try RowDataHelpers.put(&builder, allocator, field_name, try FieldValueHelpers.text(allocator, field_value));
    const row = try RowDataHelpers.finalize(&builder, allocator);
    event.setInsertData(row);

    const serializer = JsonSerializer.init();
    const json_output = try serializer.serialize(event, allocator);
    defer allocator.free(json_output);

    // The output must be valid JSON and round-trip the exact bytes back.
    try testing.expect(try std.json.validate(allocator, json_output));

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_output, .{});
    defer parsed.deinit();

    const data = parsed.value.object.get("data").?.object;
    try testing.expectEqualStrings(field_value, data.get(field_name).?.string);
}
