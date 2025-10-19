const std = @import("std");
const testing = std.testing;

const decoder_mod = @import("pg_output_decoder.zig");
const PgOutputDecoder = decoder_mod.PgOutputDecoder;
const PgOutputMessage = decoder_mod.PgOutputMessage;
const MessageType = decoder_mod.MessageType;
const TupleDataType = decoder_mod.TupleDataType;

// Helper to build binary messages
fn writeU64(buffer: []u8, value: u64) void {
    buffer[0] = @intCast((value >> 56) & 0xFF);
    buffer[1] = @intCast((value >> 48) & 0xFF);
    buffer[2] = @intCast((value >> 40) & 0xFF);
    buffer[3] = @intCast((value >> 32) & 0xFF);
    buffer[4] = @intCast((value >> 24) & 0xFF);
    buffer[5] = @intCast((value >> 16) & 0xFF);
    buffer[6] = @intCast((value >> 8) & 0xFF);
    buffer[7] = @intCast(value & 0xFF);
}

fn writeI64(buffer: []u8, value: i64) void {
    writeU64(buffer, @bitCast(value));
}

fn writeU32(buffer: []u8, value: u32) void {
    buffer[0] = @intCast((value >> 24) & 0xFF);
    buffer[1] = @intCast((value >> 16) & 0xFF);
    buffer[2] = @intCast((value >> 8) & 0xFF);
    buffer[3] = @intCast(value & 0xFF);
}

fn writeI32(buffer: []u8, value: i32) void {
    writeU32(buffer, @bitCast(value));
}

fn writeU16(buffer: []u8, value: u16) void {
    buffer[0] = @intCast((value >> 8) & 0xFF);
    buffer[1] = @intCast(value & 0xFF);
}

test "PgOutputDecoder: decode BEGIN message" {
    const allocator = testing.allocator;
    var pg_decoder = PgOutputDecoder.init(allocator);

    // Build BEGIN message: 'B' + final_lsn(8) + commit_time(8) + xid(4)
    var data: [21]u8 = undefined;
    data[0] = 'B';
    writeU64(data[1..9], 0x1234567890ABCDEF);
    writeI64(data[9..17], 1234567890);
    writeU32(data[17..21], 42);

    var msg = try pg_decoder.decode(&data);
    defer msg.deinit(allocator);

    try testing.expect(msg == .begin);
    try testing.expectEqual(@as(u64, 0x1234567890ABCDEF), msg.begin.final_lsn);
    try testing.expectEqual(@as(i64, 1234567890), msg.begin.commit_time);
    try testing.expectEqual(@as(u32, 42), msg.begin.xid);
}

test "PgOutputDecoder: decode COMMIT message" {
    const allocator = testing.allocator;
    var pg_decoder = PgOutputDecoder.init(allocator);

    // Build COMMIT message: 'C' + flags(1) + commit_lsn(8) + end_lsn(8) + commit_time(8)
    var data: [26]u8 = undefined;
    data[0] = 'C';
    data[1] = 1; // flags
    writeU64(data[2..10], 0x1000);
    writeU64(data[10..18], 0x2000);
    writeI64(data[18..26], 9999);

    var msg = try pg_decoder.decode(&data);
    defer msg.deinit(allocator);

    try testing.expect(msg == .commit);
    try testing.expectEqual(@as(u8, 1), msg.commit.flags);
    try testing.expectEqual(@as(u64, 0x1000), msg.commit.commit_lsn);
    try testing.expectEqual(@as(u64, 0x2000), msg.commit.end_lsn);
    try testing.expectEqual(@as(i64, 9999), msg.commit.commit_time);
}

test "PgOutputDecoder: decode RELATION message" {
    const allocator = testing.allocator;
    var pg_decoder = PgOutputDecoder.init(allocator);

    // Build RELATION message
    // 'R' + relation_id(4) + namespace\0 + relation_name\0 + replica_identity(1) + column_count(2) + columns
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);

    try data.append(allocator, 'R');

    // relation_id = 12345
    var rel_id_buf: [4]u8 = undefined;
    writeU32(&rel_id_buf, 12345);
    try data.appendSlice(allocator, &rel_id_buf);

    // namespace = "public"
    try data.appendSlice(allocator, "public");
    try data.append(allocator, 0);

    // relation_name = "users"
    try data.appendSlice(allocator, "users");
    try data.append(allocator, 0);

    // replica_identity = 'd' (default)
    try data.append(allocator, 'd');

    // column_count = 2
    var col_count_buf: [2]u8 = undefined;
    writeU16(&col_count_buf, 2);
    try data.appendSlice(allocator, &col_count_buf);

    // Column 1: flags=1, name="id", data_type=23 (int4), type_modifier=-1
    try data.append(allocator, 1); // flags
    try data.appendSlice(allocator, "id");
    try data.append(allocator, 0);
    var type_buf: [4]u8 = undefined;
    writeU32(&type_buf, 23);
    try data.appendSlice(allocator, &type_buf);
    writeI32(&type_buf, -1);
    try data.appendSlice(allocator, &type_buf);

    // Column 2: flags=0, name="name", data_type=25 (text), type_modifier=-1
    try data.append(allocator, 0); // flags
    try data.appendSlice(allocator, "name");
    try data.append(allocator, 0);
    writeU32(&type_buf, 25);
    try data.appendSlice(allocator, &type_buf);
    writeI32(&type_buf, -1);
    try data.appendSlice(allocator, &type_buf);

    var msg = try pg_decoder.decode(data.items);
    defer msg.deinit(allocator);

    try testing.expect(msg == .relation);
    try testing.expectEqual(@as(u32, 12345), msg.relation.relation_id);
    try testing.expectEqualStrings("public", msg.relation.namespace);
    try testing.expectEqualStrings("users", msg.relation.relation_name);
    try testing.expectEqual(@as(u8, 'd'), msg.relation.replica_identity);
    try testing.expectEqual(@as(usize, 2), msg.relation.columns.len);

    try testing.expectEqual(@as(u8, 1), msg.relation.columns[0].flags);
    try testing.expectEqualStrings("id", msg.relation.columns[0].name);
    try testing.expectEqual(@as(u32, 23), msg.relation.columns[0].data_type);

    try testing.expectEqual(@as(u8, 0), msg.relation.columns[1].flags);
    try testing.expectEqualStrings("name", msg.relation.columns[1].name);
    try testing.expectEqual(@as(u32, 25), msg.relation.columns[1].data_type);
}

test "PgOutputDecoder: decode INSERT message" {
    const allocator = testing.allocator;
    var pg_decoder = PgOutputDecoder.init(allocator);

    // Build INSERT message
    // 'I' + relation_id(4) + 'N' + column_count(2) + tuple_data
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);

    try data.append(allocator, 'I');

    // relation_id = 12345
    var buf: [4]u8 = undefined;
    writeU32(&buf, 12345);
    try data.appendSlice(allocator, &buf);

    // 'N' = new tuple
    try data.append(allocator, 'N');

    // column_count = 2
    var col_count_buf: [2]u8 = undefined;
    writeU16(&col_count_buf, 2);
    try data.appendSlice(allocator, &col_count_buf);

    // Column 1: text value "123"
    try data.append(allocator, 't'); // text
    writeU32(&buf, 3); // length
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "123");

    // Column 2: text value "Alice"
    try data.append(allocator, 't'); // text
    writeU32(&buf, 5); // length
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "Alice");

    var msg = try pg_decoder.decode(data.items);
    defer msg.deinit(allocator);

    try testing.expect(msg == .insert);
    try testing.expectEqual(@as(u32, 12345), msg.insert.relation_id);
    try testing.expectEqual(@as(usize, 2), msg.insert.new_tuple.columns.len);

    try testing.expect(msg.insert.new_tuple.columns[0].column_type == .text);
    try testing.expectEqualStrings("123", msg.insert.new_tuple.columns[0].value.?);

    try testing.expect(msg.insert.new_tuple.columns[1].column_type == .text);
    try testing.expectEqualStrings("Alice", msg.insert.new_tuple.columns[1].value.?);
}

test "PgOutputDecoder: decode UPDATE message with old tuple" {
    const allocator = testing.allocator;
    var pg_decoder = PgOutputDecoder.init(allocator);

    // Build UPDATE message
    // 'U' + relation_id(4) + 'O' + old_column_count(2) + old_tuple + 'N' + new_column_count(2) + new_tuple
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);

    try data.append(allocator, 'U');

    // relation_id = 12345
    var buf: [4]u8 = undefined;
    writeU32(&buf, 12345);
    try data.appendSlice(allocator, &buf);

    // 'O' = old tuple (full)
    try data.append(allocator, 'O');

    // old column_count = 1
    var col_count_buf: [2]u8 = undefined;
    writeU16(&col_count_buf, 1);
    try data.appendSlice(allocator, &col_count_buf);

    // Old column: text value "old_name"
    try data.append(allocator, 't');
    writeU32(&buf, 8);
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "old_name");

    // 'N' = new tuple
    try data.append(allocator, 'N');

    // new column_count = 1
    writeU16(&col_count_buf, 1);
    try data.appendSlice(allocator, &col_count_buf);

    // New column: text value "new_name"
    try data.append(allocator, 't');
    writeU32(&buf, 8);
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "new_name");

    var msg = try pg_decoder.decode(data.items);
    defer msg.deinit(allocator);

    try testing.expect(msg == .update);
    try testing.expectEqual(@as(u32, 12345), msg.update.relation_id);

    // Check old tuple
    try testing.expect(msg.update.old_tuple != null);
    try testing.expectEqual(@as(usize, 1), msg.update.old_tuple.?.columns.len);
    try testing.expectEqualStrings("old_name", msg.update.old_tuple.?.columns[0].value.?);

    // Check new tuple
    try testing.expectEqual(@as(usize, 1), msg.update.new_tuple.columns.len);
    try testing.expectEqualStrings("new_name", msg.update.new_tuple.columns[0].value.?);
}

test "PgOutputDecoder: decode DELETE message" {
    const allocator = testing.allocator;
    var pg_decoder = PgOutputDecoder.init(allocator);

    // Build DELETE message
    // 'D' + relation_id(4) + 'O' + column_count(2) + tuple_data
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);

    try data.append(allocator, 'D');

    // relation_id = 12345
    var buf: [4]u8 = undefined;
    writeU32(&buf, 12345);
    try data.appendSlice(allocator, &buf);

    // 'O' = old tuple
    try data.append(allocator, 'O');

    // column_count = 1
    var col_count_buf: [2]u8 = undefined;
    writeU16(&col_count_buf, 1);
    try data.appendSlice(allocator, &col_count_buf);

    // Column: text value "deleted_row"
    try data.append(allocator, 't');
    writeU32(&buf, 11);
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "deleted_row");

    var msg = try pg_decoder.decode(data.items);
    defer msg.deinit(allocator);

    try testing.expect(msg == .delete);
    try testing.expectEqual(@as(u32, 12345), msg.delete.relation_id);
    try testing.expectEqual(@as(usize, 1), msg.delete.old_tuple.columns.len);
    try testing.expectEqualStrings("deleted_row", msg.delete.old_tuple.columns[0].value.?);
}

test "PgOutputDecoder: decode tuple with NULL values" {
    const allocator = testing.allocator;
    var pg_decoder = PgOutputDecoder.init(allocator);

    // Build INSERT with NULL value
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);

    try data.append(allocator, 'I');

    var buf: [4]u8 = undefined;
    writeU32(&buf, 12345);
    try data.appendSlice(allocator, &buf);

    try data.append(allocator, 'N');

    var col_count_buf: [2]u8 = undefined;
    writeU16(&col_count_buf, 2);
    try data.appendSlice(allocator, &col_count_buf);

    // Column 1: text value "123"
    try data.append(allocator, 't');
    writeU32(&buf, 3);
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "123");

    // Column 2: NULL
    try data.append(allocator, 'n');

    var msg = try pg_decoder.decode(data.items);
    defer msg.deinit(allocator);

    try testing.expect(msg == .insert);
    try testing.expectEqual(@as(usize, 2), msg.insert.new_tuple.columns.len);

    try testing.expectEqualStrings("123", msg.insert.new_tuple.columns[0].value.?);

    try testing.expect(msg.insert.new_tuple.columns[1].column_type == .null);
    try testing.expect(msg.insert.new_tuple.columns[1].value == null);
}

test "PgOutputDecoder: invalid message type" {
    const allocator = testing.allocator;
    var pg_decoder = PgOutputDecoder.init(allocator);

    const data = [_]u8{'X'}; // Unknown message type

    const result = pg_decoder.decode(&data);
    try testing.expectError(decoder_mod.DecoderError.UnknownMessageType, result);
}
