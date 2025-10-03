const std = @import("std");
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const ChangeOperation = domain.ChangeOperation;
const Metadata = domain.Metadata;
const RowData = domain.RowData;
const RowDataHelpers = domain.RowDataHelpers;
const FieldValueHelpers = domain.FieldValueHelpers;

// Parser for PostgreSQL WAL field format
pub const FieldParser = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    // Parses field string like "id[integer]:1 email[character varying]:'alice@example.com'"
    // into RowData with typed values
    pub fn parseFields(self: *Self, fields_data: []const u8) !RowData {
        var builder = RowDataHelpers.createBuilder(self.allocator);
        errdefer builder.deinit(self.allocator);

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
            try RowDataHelpers.put(&builder, self.allocator, field_name, typed_value);

            // Continue from end of current value
            i = value_end;
        }

        return try RowDataHelpers.finalize(&builder, self.allocator);
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
    }
};

// PostgreSQL WAL message parser
pub const WalParser = struct {
    allocator: std.mem.Allocator,
    field_parser: FieldParser,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .field_parser = FieldParser.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.field_parser.deinit();
    }

    // Parses PostgreSQL WAL message into ChangeEvent domain model
    pub fn parse(self: *Self, wal_data: []const u8, source_name: []const u8) !?ChangeEvent {
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

        // Create metadata
        const metadata = Metadata{
            .source = source_name,
            .resource = table_name,
            .schema = schema_name,
            .timestamp = std.time.timestamp(),
            .lsn = null, // TODO: extract LSN if available
        };

        // Create event
        var event = ChangeEvent.init(operation, metadata);

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
                event.setInsertData(row);
            },
            .DELETE => {
                const row = try self.field_parser.parseFields(fields_data);
                event.setDeleteData(row);
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

                    var old_row: RowData = &[_]domain.FieldData{};
                    var new_row: RowData = &[_]domain.FieldData{};

                    if (old_fields_data.len > 0) {
                        old_row = try self.field_parser.parseFields(old_fields_data);
                    }
                    if (new_fields_data.len > 0) {
                        new_row = try self.field_parser.parseFields(new_fields_data);
                    }

                    event.setUpdateData(new_row, old_row);
                } else {
                    // Only new data (simplified format)
                    const new_row = try self.field_parser.parseFields(fields_data);
                    const old_row: RowData = &[_]domain.FieldData{};
                    event.setUpdateData(new_row, old_row);
                }
            },
            .UNKNOWN => unreachable,
        }

        return event;
    }
};

// Tests
test "FieldParser parse simple fields" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    var parser = FieldParser.init(allocator);
    defer parser.deinit();

    const fields_data = "id[integer]:1 email[character varying]:'alice@example.com' active[boolean]:true";

    var row = try parser.parseFields(fields_data);
    defer RowDataHelpers.deinit(&row, allocator);

    // Check that fields were parsed correctly
    try testing.expect(RowDataHelpers.hasField(row, "id"));
    try testing.expect(RowDataHelpers.hasField(row, "email"));
    try testing.expect(RowDataHelpers.hasField(row, "active"));

    const id_value = RowDataHelpers.getField(row, "id").?;
    try testing.expectEqual(@as(i64, 1), id_value.integer);

    const email_value = RowDataHelpers.getField(row, "email").?;
    try testing.expectEqualStrings("alice@example.com", email_value.string);

    const active_value = RowDataHelpers.getField(row, "active").?;
    try testing.expectEqual(true, active_value.bool);
}

test "WalParser parse INSERT" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    var parser = WalParser.init(allocator);
    defer parser.deinit();

    const wal_data = "table public.users: INSERT: id[integer]:1 email[character varying]:'alice@example.com' active[boolean]:true";

    const event_opt = try parser.parse(wal_data, "postgres");
    try testing.expect(event_opt != null);

    var event = event_opt.?;
    defer event.deinit(allocator);

    try testing.expectEqualStrings("INSERT", event.op);
    try testing.expectEqualStrings("postgres", event.meta.source);
    try testing.expectEqualStrings("users", event.meta.resource);
    try testing.expectEqualStrings("public", event.meta.schema);

    // Check that data was parsed correctly
    switch (event.data) {
        .insert => |data| {
            try testing.expect(RowDataHelpers.hasField(data, "id"));
            try testing.expect(RowDataHelpers.hasField(data, "email"));
            try testing.expect(RowDataHelpers.hasField(data, "active"));

            const id_value = RowDataHelpers.getField(data, "id").?;
            try testing.expectEqual(@as(i64, 1), id_value.integer);
        },
        else => try testing.expect(false), // Should be insert
    }
}
