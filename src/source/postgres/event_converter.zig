const std = @import("std");
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const ChangeOperation = domain.ChangeOperation;
const Metadata = domain.Metadata;
const RowData = domain.RowData;
const RowDataHelpers = domain.RowDataHelpers;
const FieldValueHelpers = domain.FieldValueHelpers;
const constants = @import("constants");

const pg_output_decoder = @import("pg_output_decoder.zig");
const PgOutputMessage = pg_output_decoder.PgOutputMessage;

const relation_registry = @import("relation_registry.zig");
const RelationRegistry = relation_registry.RelationRegistry;

const value_converter = @import("value_converter.zig");

pub const ConversionError = error{ConversionFailed};

/// Converts pgoutput messages into domain ChangeEvents.
///
/// This is the source adapter's conversion layer: it turns PostgreSQL-specific
/// messages into the source-agnostic domain model. It performs no I/O, so it can
/// be exercised in isolation from PostgresSource. Column values are delegated to
/// `value_converter`, keeping the value-level and event-level concerns separate.
pub const EventConverter = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    /// Process a PgOutputMessage and convert it to a ChangeEvent.
    /// Returns null for messages that don't produce ChangeEvents (BEGIN, COMMIT, RELATION).
    pub fn processMessage(self: *Self, io: std.Io, batch_allocator: std.mem.Allocator, pg_msg: PgOutputMessage, registry: *RelationRegistry) ConversionError!?ChangeEvent {
        switch (pg_msg) {
            .begin, .commit => {
                return null;
            },
            .relation => |rel| {
                registry.register(rel) catch |err| {
                    std.log.warn("Failed to register relation: {}", .{err});
                    return ConversionError.ConversionFailed;
                };
                return null;
            },
            .insert => |ins| {
                return self.convertInsert(io, batch_allocator, ins, registry) catch |err| {
                    std.log.warn("Failed to convert INSERT: {}", .{err});
                    return ConversionError.ConversionFailed;
                };
            },
            .update => |upd| {
                return self.convertUpdate(io, batch_allocator, upd, registry) catch |err| {
                    std.log.warn("Failed to convert UPDATE: {}", .{err});
                    return ConversionError.ConversionFailed;
                };
            },
            .delete => |del| {
                return self.convertDelete(io, batch_allocator, del, registry) catch |err| {
                    std.log.warn("Failed to convert DELETE: {}", .{err});
                    return ConversionError.ConversionFailed;
                };
            },
        }
    }

    fn convertInsert(self: *Self, io: std.Io, batch_allocator: std.mem.Allocator, insert_msg: anytype, registry: *RelationRegistry) !ChangeEvent {
        const rel_info = try registry.get(insert_msg.relation_id);

        const metadata = Metadata{
            .source = try batch_allocator.dupe(u8, "postgres"),
            .resource = try batch_allocator.dupe(u8, rel_info.relation_name),
            .schema = try batch_allocator.dupe(u8, rel_info.namespace),
            .timestamp = std.Io.Timestamp.now(io, .real).toSeconds(),
            .lsn = null,
        };

        var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);

        const row_data = try self.tupleToRowData(batch_allocator, insert_msg.new_tuple, rel_info);
        event.setInsertData(row_data);

        return event;
    }

    fn convertUpdate(self: *Self, io: std.Io, batch_allocator: std.mem.Allocator, update_msg: anytype, registry: *RelationRegistry) !ChangeEvent {
        const rel_info = try registry.get(update_msg.relation_id);

        const metadata = Metadata{
            .source = try batch_allocator.dupe(u8, "postgres"),
            .resource = try batch_allocator.dupe(u8, rel_info.relation_name),
            .schema = try batch_allocator.dupe(u8, rel_info.namespace),
            .timestamp = std.Io.Timestamp.now(io, .real).toSeconds(),
            .lsn = null,
        };

        var event = ChangeEvent.init(ChangeOperation.UPDATE, metadata);

        const new_row = try self.tupleToRowData(batch_allocator, update_msg.new_tuple, rel_info);
        const old_row = if (update_msg.old_tuple) |old_tuple|
            try self.tupleToRowData(batch_allocator, old_tuple, rel_info)
        else
            try batch_allocator.alloc(domain.FieldData, 0);

        event.setUpdateData(new_row, old_row);

        return event;
    }

    fn convertDelete(self: *Self, io: std.Io, batch_allocator: std.mem.Allocator, delete_msg: anytype, registry: *RelationRegistry) !ChangeEvent {
        const rel_info = try registry.get(delete_msg.relation_id);

        const metadata = Metadata{
            .source = try batch_allocator.dupe(u8, "postgres"),
            .resource = try batch_allocator.dupe(u8, rel_info.relation_name),
            .schema = try batch_allocator.dupe(u8, rel_info.namespace),
            .timestamp = std.Io.Timestamp.now(io, .real).toSeconds(),
            .lsn = null,
        };

        var event = ChangeEvent.init(ChangeOperation.DELETE, metadata);

        const row_data = try self.tupleToRowData(batch_allocator, delete_msg.old_tuple, rel_info);
        event.setDeleteData(row_data);

        return event;
    }

    fn tupleToRowData(self: *Self, batch_allocator: std.mem.Allocator, tuple: anytype, rel_info: anytype) !RowData {
        _ = self;
        var builder = RowDataHelpers.createBuilder(batch_allocator);
        errdefer {
            for (builder.items) |field| {
                batch_allocator.free(field.name);
                if (field.value == .string) {
                    batch_allocator.free(field.value.string);
                }
            }
            builder.deinit(batch_allocator);
        }

        for (tuple.columns, 0..) |col, i| {
            const col_name = rel_info.columns[i].name;

            if (col.value) |val| {
                const field_value = try value_converter.convert(batch_allocator, rel_info.columns[i].data_type, val);
                try RowDataHelpers.put(&builder, batch_allocator, col_name, field_value);
            } else if (col.column_type == .unchanged_toast) {
                // Postgres didn't resend the unchanged TOAST value; emit a placeholder
                // so the column stays in the payload instead of looking like a real NULL.
                const placeholder = try FieldValueHelpers.text(batch_allocator, constants.UNKNOWN_VALUE_PLACEHOLDER);
                try RowDataHelpers.put(&builder, batch_allocator, col_name, placeholder);
            } else {
                try RowDataHelpers.put(&builder, batch_allocator, col_name, FieldValueHelpers.null_value());
            }
        }

        return try RowDataHelpers.finalize(&builder, batch_allocator);
    }
};

// Unit Tests
const testing = std.testing;
const RelationRegistryError = relation_registry.RelationRegistryError;

test "convertInsert: basic INSERT message to ChangeEvent" {
    const allocator = testing.allocator;

    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();
    var converter = EventConverter.init();

    // Register test relation (id=100, public.users, columns: id, name)
    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 100,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 2),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = pg_output_decoder.RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23, // int4
        .type_modifier = -1,
    };
    rel_msg.columns[1] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25, // text
        .type_modifier = -1,
    };

    try registry.register(rel_msg);

    // Create INSERT message
    var insert_msg = pg_output_decoder.InsertMessage{
        .relation_id = 100,
        .new_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 2),
        },
    };
    insert_msg.new_tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "1"),
    };
    insert_msg.new_tuple.columns[1] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Alice"),
    };
    defer insert_msg.new_tuple.deinit(allocator);

    var event = try converter.convertInsert(std.testing.io, allocator, insert_msg, &registry);
    defer event.deinit(allocator);

    // Verify: operation type
    try testing.expectEqualStrings("INSERT", event.op);

    // Verify: metadata
    try testing.expectEqualStrings("postgres", event.meta.source);
    try testing.expectEqualStrings("users", event.meta.resource);
    try testing.expectEqualStrings("public", event.meta.schema);
    try testing.expect(event.meta.timestamp > 0);

    // Verify: insert_data present
    try testing.expect(event.data == .insert);
    const insert_data = event.data.insert;
    try testing.expectEqual(@as(usize, 2), insert_data.len);

    // Verify: field values
    try testing.expectEqualStrings("id", insert_data[0].name);
    try testing.expect(insert_data[0].value == .integer);
    try testing.expectEqual(@as(i64, 1), insert_data[0].value.integer);

    try testing.expectEqualStrings("name", insert_data[1].name);
    try testing.expect(insert_data[1].value == .string);
    try testing.expectEqualStrings("Alice", insert_data[1].value.string);
}

test "convertUpdate: UPDATE message with old and new tuples" {
    const allocator = testing.allocator;

    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();
    var converter = EventConverter.init();

    // Register test relation (id=100, public.users, columns: id, name)
    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 100,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 2),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = pg_output_decoder.RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23, // int4
        .type_modifier = -1,
    };
    rel_msg.columns[1] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25, // text
        .type_modifier = -1,
    };

    try registry.register(rel_msg);

    // Create UPDATE message with old and new tuples
    var update_msg = pg_output_decoder.UpdateMessage{
        .relation_id = 100,
        .old_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 2),
        },
        .new_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 2),
        },
    };
    defer update_msg.deinit(allocator);

    // Old tuple: id=1, name=Alice
    update_msg.old_tuple.?.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "1"),
    };
    update_msg.old_tuple.?.columns[1] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Alice"),
    };

    // New tuple: id=1, name=Bob
    update_msg.new_tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "1"),
    };
    update_msg.new_tuple.columns[1] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Bob"),
    };

    var event = try converter.convertUpdate(std.testing.io, allocator, update_msg, &registry);
    defer event.deinit(allocator);

    // Verify: operation type
    try testing.expectEqualStrings("UPDATE", event.op);

    // Verify: metadata
    try testing.expectEqualStrings("postgres", event.meta.source);
    try testing.expectEqualStrings("users", event.meta.resource);
    try testing.expectEqualStrings("public", event.meta.schema);
    try testing.expect(event.meta.timestamp > 0);

    // Verify: update data present
    try testing.expect(event.data == .update);
    const new_data = event.data.update.new;
    const old_data = event.data.update.old;

    // Verify: new_data
    try testing.expectEqual(@as(usize, 2), new_data.len);
    try testing.expectEqualStrings("id", new_data[0].name);
    try testing.expectEqual(@as(i64, 1), new_data[0].value.integer);
    try testing.expectEqualStrings("name", new_data[1].name);
    try testing.expectEqualStrings("Bob", new_data[1].value.string);

    // Verify: old_data
    try testing.expectEqual(@as(usize, 2), old_data.len);
    try testing.expectEqualStrings("id", old_data[0].name);
    try testing.expectEqual(@as(i64, 1), old_data[0].value.integer);
    try testing.expectEqualStrings("name", old_data[1].name);
    try testing.expectEqualStrings("Alice", old_data[1].value.string);
}

test "convertDelete: DELETE message to ChangeEvent" {
    const allocator = testing.allocator;

    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();
    var converter = EventConverter.init();

    // Register test relation
    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 100,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 2),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = pg_output_decoder.RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23,
        .type_modifier = -1,
    };
    rel_msg.columns[1] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25,
        .type_modifier = -1,
    };

    try registry.register(rel_msg);

    // Create DELETE message
    var delete_msg = pg_output_decoder.DeleteMessage{
        .relation_id = 100,
        .old_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 2),
        },
    };
    defer delete_msg.deinit(allocator);

    delete_msg.old_tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "1"),
    };
    delete_msg.old_tuple.columns[1] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Alice"),
    };

    var event = try converter.convertDelete(std.testing.io, allocator, delete_msg, &registry);
    defer event.deinit(allocator);

    // Verify: operation type
    try testing.expectEqualStrings("DELETE", event.op);

    // Verify: metadata
    try testing.expectEqualStrings("postgres", event.meta.source);
    try testing.expectEqualStrings("users", event.meta.resource);
    try testing.expectEqualStrings("public", event.meta.schema);

    // Verify: delete_data present
    try testing.expect(event.data == .delete);
    const delete_data = event.data.delete;
    try testing.expectEqual(@as(usize, 2), delete_data.len);
    try testing.expectEqualStrings("id", delete_data[0].name);
    try testing.expectEqual(@as(i64, 1), delete_data[0].value.integer);
    try testing.expectEqualStrings("name", delete_data[1].name);
    try testing.expectEqualStrings("Alice", delete_data[1].value.string);
}

test "tupleToRowData: convert tuple with text values to RowData" {
    const allocator = testing.allocator;

    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();
    var converter = EventConverter.init();

    // Register relation with 3 columns: id, name, email
    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 200,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 3),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = pg_output_decoder.RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23,
        .type_modifier = -1,
    };
    rel_msg.columns[1] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25,
        .type_modifier = -1,
    };
    rel_msg.columns[2] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "email"),
        .data_type = 25,
        .type_modifier = -1,
    };

    try registry.register(rel_msg);

    // Create tuple with text values
    var tuple = pg_output_decoder.TupleMessage{
        .columns = try allocator.alloc(pg_output_decoder.TupleData, 3),
    };
    defer tuple.deinit(allocator);

    tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "42"),
    };
    tuple.columns[1] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "John"),
    };
    tuple.columns[2] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "john@example.com"),
    };

    const rel_info = try registry.get(200);

    const row_data = try converter.tupleToRowData(allocator, tuple, rel_info);
    defer {
        for (row_data) |field| {
            allocator.free(field.name);
            if (field.value == .string) {
                allocator.free(field.value.string);
            }
        }
        allocator.free(row_data);
    }

    // Verify: 3 fields
    try testing.expectEqual(@as(usize, 3), row_data.len);

    // Verify: field 0 (id)
    try testing.expectEqualStrings("id", row_data[0].name);
    try testing.expect(row_data[0].value == .integer);
    try testing.expectEqual(@as(i64, 42), row_data[0].value.integer);

    // Verify: field 1 (name)
    try testing.expectEqualStrings("name", row_data[1].name);
    try testing.expect(row_data[1].value == .string);
    try testing.expectEqualStrings("John", row_data[1].value.string);

    // Verify: field 2 (email)
    try testing.expectEqualStrings("email", row_data[2].name);
    try testing.expect(row_data[2].value == .string);
    try testing.expectEqualStrings("john@example.com", row_data[2].value.string);
}

test "tupleToRowData: handle NULL values in tuple" {
    const allocator = testing.allocator;

    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();
    var converter = EventConverter.init();

    // Register relation with 3 columns
    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 300,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 3),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = pg_output_decoder.RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23,
        .type_modifier = -1,
    };
    rel_msg.columns[1] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25,
        .type_modifier = -1,
    };
    rel_msg.columns[2] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "email"),
        .data_type = 25,
        .type_modifier = -1,
    };

    try registry.register(rel_msg);

    // Create tuple with NULL values: id=1, name=NULL, email="test@example.com"
    var tuple = pg_output_decoder.TupleMessage{
        .columns = try allocator.alloc(pg_output_decoder.TupleData, 3),
    };
    defer tuple.deinit(allocator);

    tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "1"),
    };
    tuple.columns[1] = pg_output_decoder.TupleData{
        .column_type = .null,
        .value = null, // NULL value
    };
    tuple.columns[2] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "test@example.com"),
    };

    const rel_info = try registry.get(300);

    const row_data = try converter.tupleToRowData(allocator, tuple, rel_info);
    defer {
        for (row_data) |field| {
            allocator.free(field.name);
            if (field.value == .string) {
                allocator.free(field.value.string);
            }
        }
        allocator.free(row_data);
    }

    // Verify: 3 fields
    try testing.expectEqual(@as(usize, 3), row_data.len);

    // Verify: field 0 (id) - has value
    try testing.expectEqualStrings("id", row_data[0].name);
    try testing.expect(row_data[0].value == .integer);
    try testing.expectEqual(@as(i64, 1), row_data[0].value.integer);

    // Verify: field 1 (name) - NULL
    try testing.expectEqualStrings("name", row_data[1].name);
    try testing.expect(row_data[1].value == .null);

    // Verify: field 2 (email) - has value
    try testing.expectEqualStrings("email", row_data[2].name);
    try testing.expect(row_data[2].value == .string);
    try testing.expectEqualStrings("test@example.com", row_data[2].value.string);
}

test "tupleToRowData: unchanged TOAST column becomes the placeholder" {
    const allocator = testing.allocator;

    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();
    var converter = EventConverter.init();

    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 400,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "articles"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 3),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = .{ .flags = 1, .name = try allocator.dupe(u8, "id"), .data_type = 23, .type_modifier = -1 };
    rel_msg.columns[1] = .{ .flags = 0, .name = try allocator.dupe(u8, "body"), .data_type = 25, .type_modifier = -1 };
    rel_msg.columns[2] = .{ .flags = 0, .name = try allocator.dupe(u8, "title"), .data_type = 25, .type_modifier = -1 };

    try registry.register(rel_msg);

    // UPDATE that didn't touch body: the decoder yields a null value with the
    // unchanged-TOAST marker, which tupleToRowData turns into the placeholder.
    var tuple = pg_output_decoder.TupleMessage{
        .columns = try allocator.alloc(pg_output_decoder.TupleData, 3),
    };
    defer tuple.deinit(allocator);

    tuple.columns[0] = .{ .column_type = .text, .value = try allocator.dupe(u8, "1") };
    tuple.columns[1] = .{ .column_type = .unchanged_toast, .value = null };
    tuple.columns[2] = .{ .column_type = .text, .value = try allocator.dupe(u8, "Hello") };

    const rel_info = try registry.get(400);

    const row_data = try converter.tupleToRowData(allocator, tuple, rel_info);
    defer {
        for (row_data) |field| {
            allocator.free(field.name);
            if (field.value == .string) {
                allocator.free(field.value.string);
            }
        }
        allocator.free(row_data);
    }

    // body stays in the row as the placeholder, keeping the schema stable.
    try testing.expectEqual(@as(usize, 3), row_data.len);
    try testing.expectEqualStrings("body", row_data[1].name);
    try testing.expect(row_data[1].value == .string);
    try testing.expectEqualStrings(constants.UNKNOWN_VALUE_PLACEHOLDER, row_data[1].value.string);
}

test "convertInsert: error when relation not found in registry" {
    const allocator = testing.allocator;

    // Empty registry (no relations registered)
    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();
    var converter = EventConverter.init();

    // Create INSERT message for non-existent relation (id=999)
    var insert_msg = pg_output_decoder.InsertMessage{
        .relation_id = 999, // This relation is NOT registered
        .new_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 1),
        },
    };
    defer insert_msg.new_tuple.deinit(allocator);

    insert_msg.new_tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "test"),
    };

    const result = converter.convertInsert(std.testing.io, allocator, insert_msg, &registry);

    // Verify: error is RelationNotFound
    try testing.expectError(RelationRegistryError.RelationNotFound, result);
}
