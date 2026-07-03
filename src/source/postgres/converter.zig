const std = @import("std");
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const ChangeOperation = domain.ChangeOperation;
const Metadata = domain.Metadata;
const RowData = domain.RowData;
const RowDataHelpers = domain.RowDataHelpers;
const FieldValueHelpers = domain.FieldValueHelpers;
const FieldValue = domain.FieldValue;
const constants = @import("constants");

const pg_output_decoder = @import("pg_output_decoder.zig");
const PgOutputMessage = pg_output_decoder.PgOutputMessage;

const relation_registry = @import("relation_registry.zig");
const RelationRegistry = relation_registry.RelationRegistry;

pub const ConversionError = error{ConversionFailed};

// Event level: a pgoutput message -> domain ChangeEvent.

/// Process a PgOutputMessage and convert it to a ChangeEvent.
/// Returns null for messages that don't produce ChangeEvents (BEGIN, COMMIT, RELATION).
pub fn processMessage(io: std.Io, allocator: std.mem.Allocator, pg_msg: PgOutputMessage, registry: *RelationRegistry) ConversionError!?ChangeEvent {
    switch (pg_msg) {
        .begin, .commit => return null,
        .relation => |rel| {
            registry.register(rel) catch |err| {
                std.log.warn("Failed to register relation: {}", .{err});
                return ConversionError.ConversionFailed;
            };
            return null;
        },
        .insert => |ins| {
            return convertInsert(io, allocator, ins, registry) catch |err| {
                std.log.warn("Failed to convert INSERT: {}", .{err});
                return ConversionError.ConversionFailed;
            };
        },
        .update => |upd| {
            return convertUpdate(io, allocator, upd, registry) catch |err| {
                std.log.warn("Failed to convert UPDATE: {}", .{err});
                return ConversionError.ConversionFailed;
            };
        },
        .delete => |del| {
            return convertDelete(io, allocator, del, registry) catch |err| {
                std.log.warn("Failed to convert DELETE: {}", .{err});
                return ConversionError.ConversionFailed;
            };
        },
    }
}

fn convertInsert(io: std.Io, allocator: std.mem.Allocator, insert_msg: anytype, registry: *RelationRegistry) !ChangeEvent {
    const rel_info = try registry.get(insert_msg.relation_id);
    var event = ChangeEvent.init(ChangeOperation.INSERT, try buildMetadata(io, allocator, rel_info));
    event.setInsertData(try tupleToRowData(allocator, insert_msg.new_tuple, rel_info));
    return event;
}

fn convertUpdate(io: std.Io, allocator: std.mem.Allocator, update_msg: anytype, registry: *RelationRegistry) !ChangeEvent {
    const rel_info = try registry.get(update_msg.relation_id);
    var event = ChangeEvent.init(ChangeOperation.UPDATE, try buildMetadata(io, allocator, rel_info));

    const new_row = try tupleToRowData(allocator, update_msg.new_tuple, rel_info);
    const old_row = if (update_msg.old_tuple) |old_tuple|
        try tupleToRowData(allocator, old_tuple, rel_info)
    else
        try allocator.alloc(domain.FieldData, 0);

    event.setUpdateData(new_row, old_row);
    return event;
}

fn convertDelete(io: std.Io, allocator: std.mem.Allocator, delete_msg: anytype, registry: *RelationRegistry) !ChangeEvent {
    const rel_info = try registry.get(delete_msg.relation_id);
    var event = ChangeEvent.init(ChangeOperation.DELETE, try buildMetadata(io, allocator, rel_info));
    event.setDeleteData(try tupleToRowData(allocator, delete_msg.old_tuple, rel_info));
    return event;
}

// Strings are duped so the event owns them independently of the relation registry.
fn buildMetadata(io: std.Io, allocator: std.mem.Allocator, rel_info: anytype) !Metadata {
    return .{
        .source = try allocator.dupe(u8, "postgres"),
        .resource = try allocator.dupe(u8, rel_info.relation_name),
        .schema = try allocator.dupe(u8, rel_info.namespace),
        .timestamp = std.Io.Timestamp.now(io, .real).toSeconds(),
        .lsn = null,
    };
}

fn tupleToRowData(allocator: std.mem.Allocator, tuple: anytype, rel_info: anytype) !RowData {
    var builder = RowDataHelpers.createBuilder(allocator);
    errdefer {
        for (builder.items) |field| {
            allocator.free(field.name);
            if (field.value == .string) {
                allocator.free(field.value.string);
            }
        }
        builder.deinit(allocator);
    }

    for (tuple.columns, 0..) |col, i| {
        const col_name = rel_info.columns[i].name;

        if (col.value) |val| {
            const field_value = try mapValue(allocator, rel_info.columns[i].data_type, val);
            try RowDataHelpers.put(&builder, allocator, col_name, field_value);
        } else if (col.column_type == .unchanged_toast) {
            // Postgres didn't resend the unchanged TOAST value; emit a placeholder
            // so the column stays in the payload instead of looking like a real NULL.
            const placeholder = try FieldValueHelpers.text(allocator, constants.UNKNOWN_VALUE_PLACEHOLDER);
            try RowDataHelpers.put(&builder, allocator, col_name, placeholder);
        } else {
            try RowDataHelpers.put(&builder, allocator, col_name, FieldValueHelpers.null_value());
        }
    }

    return try RowDataHelpers.finalize(&builder, allocator);
}

// Value level: a single column value (OID + text) -> domain FieldValue.

// PostgreSQL built-in type OIDs we upgrade from text to native JSON types.
// Values are stable, hardcoded in Postgres itself:
// https://github.com/postgres/postgres/blob/master/src/include/catalog/pg_type.dat
// Non-exhaustive: any OID we don't list stays a JSON string.
const Oid = enum(u32) {
    bool = 16,
    int8 = 20,
    int2 = 21,
    int4 = 23,
    float4 = 700,
    float8 = 701,
    numeric = 1700,
    _,
};

// Map a text-format pgoutput value to a typed JSON value based on the column OID.
//
// pgoutput always delivers values as text (`"1"`, `"t"`), so without this every
// field would serialize as a JSON string. Here we promote the common scalar types
// to real JSON numbers and booleans. Anything we can't map safely stays a string,
// which keeps the output valid JSON and never loses precision.
//
// Only the `.string` branch allocates (it dupes into caller-owned memory); the
// numeric and boolean branches return by value.
fn mapValue(allocator: std.mem.Allocator, oid: u32, text: []const u8) !FieldValue {
    switch (@as(Oid, @enumFromInt(oid))) {
        .int2, .int4, .int8 => {
            const n = std.fmt.parseInt(i64, text, 10) catch return FieldValueHelpers.text(allocator, text);
            return FieldValueHelpers.integer(n);
        },
        .float4, .float8 => {
            const f = std.fmt.parseFloat(f64, text) catch return FieldValueHelpers.text(allocator, text);
            // NaN and +/-Infinity are valid Postgres floats but not valid JSON
            // numbers, so fall back to the text form for them.
            if (!std.math.isFinite(f)) return FieldValueHelpers.text(allocator, text);
            return FieldValueHelpers.float(f);
        },
        // pgoutput always sends bool as exactly "t" or "f".
        .bool => return FieldValueHelpers.boolean(std.mem.eql(u8, text, "t")),
        // numeric carries arbitrary precision and can be NaN/Infinity, so a JSON
        // number would lose digits or be invalid. Keep the raw Postgres text, in the
        // spirit of Debezium's decimal.handling.mode=string (its default "precise"
        // mode throws on NaN/Infinity). We pass Postgres's own spelling
        // ("NaN"/"Infinity"), matching our float branch; Debezium's string mode
        // instead emits enum names ("NAN"/"POSITIVE_INFINITY").
        .numeric, _ => return FieldValueHelpers.text(allocator, text),
    }
}

// Tests

const testing = std.testing;
const RelationRegistryError = relation_registry.RelationRegistryError;

// Value level

test "mapValue: integer types become JSON integers" {
    const allocator = testing.allocator;
    for ([_]u32{ 21, 23, 20 }) |oid| {
        const v = try mapValue(allocator, oid, "42");
        try testing.expect(v == .integer);
        try testing.expectEqual(@as(i64, 42), v.integer);
    }

    const neg = try mapValue(allocator, 20, "-9223372036854775808");
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), neg.integer);
}

test "mapValue: float types become JSON floats" {
    const allocator = testing.allocator;
    for ([_]u32{ 700, 701 }) |oid| {
        const v = try mapValue(allocator, oid, "3.5");
        try testing.expect(v == .float);
        try testing.expectEqual(@as(f64, 3.5), v.float);
    }
}

test "mapValue: non-finite floats fall back to string" {
    const allocator = testing.allocator;
    for ([_]u32{ 700, 701 }) |oid| {
        for ([_][]const u8{ "NaN", "Infinity", "-Infinity" }) |text| {
            const v = try mapValue(allocator, oid, text);
            defer allocator.free(v.string);
            try testing.expect(v == .string);
            try testing.expectEqualStrings(text, v.string);
        }
    }
}

test "mapValue: bool maps t/f to JSON boolean" {
    const allocator = testing.allocator;
    const t = try mapValue(allocator, 16, "t");
    try testing.expect(t == .bool and t.bool == true);
    const f = try mapValue(allocator, 16, "f");
    try testing.expect(f == .bool and f.bool == false);
}

test "mapValue: numeric stays a string" {
    const allocator = testing.allocator;
    const v = try mapValue(allocator, 1700, "12345.6789");
    defer allocator.free(v.string);
    try testing.expect(v == .string);
    try testing.expectEqualStrings("12345.6789", v.string);
}

test "mapValue: unknown OID stays a string" {
    const allocator = testing.allocator;
    // 25 = text
    const v = try mapValue(allocator, 25, "hello");
    defer allocator.free(v.string);
    try testing.expect(v == .string);
    try testing.expectEqualStrings("hello", v.string);
}

test "mapValue: unparseable integer falls back to string" {
    const allocator = testing.allocator;
    const v = try mapValue(allocator, 23, "not-a-number");
    defer allocator.free(v.string);
    try testing.expect(v == .string);
    try testing.expectEqualStrings("not-a-number", v.string);
}

test "mapValue: unparseable float falls back to string" {
    const allocator = testing.allocator;
    const v = try mapValue(allocator, 701, "not-a-float");
    defer allocator.free(v.string);
    try testing.expect(v == .string);
    try testing.expectEqualStrings("not-a-float", v.string);
}

// Event level

test "convertInsert: basic INSERT message to ChangeEvent" {
    const allocator = testing.allocator;

    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();

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

    var event = try convertInsert(std.testing.io, allocator, insert_msg, &registry);
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

    var event = try convertUpdate(std.testing.io, allocator, update_msg, &registry);
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

    var event = try convertDelete(std.testing.io, allocator, delete_msg, &registry);
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

    const row_data = try tupleToRowData(allocator, tuple, rel_info);
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

    const row_data = try tupleToRowData(allocator, tuple, rel_info);
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

    const row_data = try tupleToRowData(allocator, tuple, rel_info);
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

    const result = convertInsert(std.testing.io, allocator, insert_msg, &registry);

    // Verify: error is RelationNotFound
    try testing.expectError(RelationRegistryError.RelationNotFound, result);
}
