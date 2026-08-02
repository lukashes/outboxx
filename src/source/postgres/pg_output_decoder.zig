const std = @import("std");

pub const DecoderError = error{
    InvalidMessage,
    UnknownMessageType,
    OutOfMemory,
    InvalidTupleData,
};

/// Message type identifiers from the pgoutput protocol.
pub const MessageType = enum(u8) {
    begin = 'B',
    commit = 'C',
    relation = 'R',
    insert = 'I',
    update = 'U',
    delete = 'D',
    origin = 'O',
    data_type = 'Y',
    truncate = 'T',
    _,
};

pub const TupleDataType = enum(u8) {
    null = 'n',
    unchanged_toast = 'u',
    text = 't',
    binary = 'b',
    _,
};

pub const BeginMessage = struct {
    final_lsn: u64,
    commit_time: i64,
    xid: u32,
};

pub const CommitMessage = struct {
    flags: u8,
    commit_lsn: u64,
    end_lsn: u64,
    commit_time: i64,
};

pub const RelationMessageColumn = struct {
    flags: u8,
    name: []const u8,
    data_type: u32,
    type_modifier: i32,

    pub fn deinit(self: *RelationMessageColumn, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const RelationMessage = struct {
    relation_id: u32,
    namespace: []const u8,
    relation_name: []const u8,
    replica_identity: u8,
    columns: []RelationMessageColumn,

    pub fn deinit(self: *RelationMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.relation_name);
        for (self.columns) |*col| {
            col.deinit(allocator);
        }
        allocator.free(self.columns);
    }
};

pub const TupleData = struct {
    column_type: TupleDataType,
    value: ?[]const u8,

    pub fn deinit(self: *TupleData, allocator: std.mem.Allocator) void {
        if (self.value) |v| {
            allocator.free(v);
        }
    }
};

pub const TupleMessage = struct {
    columns: []TupleData,

    pub fn deinit(self: *TupleMessage, allocator: std.mem.Allocator) void {
        for (self.columns) |*col| {
            col.deinit(allocator);
        }
        allocator.free(self.columns);
    }
};

pub const InsertMessage = struct {
    relation_id: u32,
    new_tuple: TupleMessage,

    pub fn deinit(self: *InsertMessage, allocator: std.mem.Allocator) void {
        self.new_tuple.deinit(allocator);
    }
};

pub const UpdateMessage = struct {
    relation_id: u32,
    old_tuple: ?TupleMessage,
    new_tuple: TupleMessage,

    pub fn deinit(self: *UpdateMessage, allocator: std.mem.Allocator) void {
        if (self.old_tuple) |*old| {
            old.deinit(allocator);
        }
        self.new_tuple.deinit(allocator);
    }
};

pub const DeleteMessage = struct {
    relation_id: u32,
    old_tuple: TupleMessage,

    pub fn deinit(self: *DeleteMessage, allocator: std.mem.Allocator) void {
        self.old_tuple.deinit(allocator);
    }
};

/// A decoded pgoutput logical replication message.
pub const PgOutputMessage = union(enum) {
    begin: BeginMessage,
    commit: CommitMessage,
    relation: RelationMessage,
    insert: InsertMessage,
    update: UpdateMessage,
    delete: DeleteMessage,
    /// A message type we consume but don't turn into a change event (truncate,
    /// type, origin). Its LSN is still confirmed, like BEGIN/COMMIT.
    skip,

    pub fn deinit(self: *PgOutputMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .begin, .commit, .skip => {},
            .relation => |*rel| rel.deinit(allocator),
            .insert => |*ins| ins.deinit(allocator),
            .update => |*upd| upd.deinit(allocator),
            .delete => |*del| del.deinit(allocator),
        }
    }
};

/// Parses raw pgoutput bytes into typed PgOutputMessage values.
pub const PgOutputDecoder = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Decode one pgoutput message into a typed PgOutputMessage.
    pub fn decode(self: *Self, allocator: std.mem.Allocator, data: []const u8) DecoderError!PgOutputMessage {
        self.allocator = allocator; // decode into the caller's (per-batch) allocator

        if (data.len == 0) {
            return DecoderError.InvalidMessage;
        }

        const msg_type: MessageType = @enumFromInt(data[0]);

        switch (msg_type) {
            .begin => return PgOutputMessage{ .begin = try self.decodeBegin(data[1..]) },
            .commit => return PgOutputMessage{ .commit = try self.decodeCommit(data[1..]) },
            .relation => return PgOutputMessage{ .relation = try self.decodeRelation(data[1..]) },
            .insert => return PgOutputMessage{ .insert = try self.decodeInsert(data[1..]) },
            .update => return PgOutputMessage{ .update = try self.decodeUpdate(data[1..]) },
            .delete => return PgOutputMessage{ .delete = try self.decodeDelete(data[1..]) },
            // Consume the types that carry no row change we emit, so their LSN is
            // confirmed instead of crash-looping the pipeline.
            .truncate => {
                std.log.info("Detected TRUNCATE on source", .{});
                return .skip;
            },
            .data_type, .origin => {
                std.log.debug("Skipping pgoutput message type: {c}", .{data[0]});
                return .skip;
            },
            else => {
                std.log.warn("Unknown pgoutput message type: {c} (0x{x})", .{ @as(u8, @intFromEnum(msg_type)), @as(u8, @intFromEnum(msg_type)) });
                return DecoderError.UnknownMessageType;
            },
        }
    }

    fn decodeBegin(self: *Self, data: []const u8) DecoderError!BeginMessage {
        _ = self;
        if (data.len < 20) return DecoderError.InvalidMessage;

        return BeginMessage{
            .final_lsn = readU64(data[0..8]),
            .commit_time = readI64(data[8..16]),
            .xid = readU32(data[16..20]),
        };
    }

    fn decodeCommit(self: *Self, data: []const u8) DecoderError!CommitMessage {
        _ = self;
        if (data.len < 25) return DecoderError.InvalidMessage;

        return CommitMessage{
            .flags = data[0],
            .commit_lsn = readU64(data[1..9]),
            .end_lsn = readU64(data[9..17]),
            .commit_time = readI64(data[17..25]),
        };
    }

    fn decodeRelation(self: *Self, data: []const u8) DecoderError!RelationMessage {
        if (data.len < 7) return DecoderError.InvalidMessage;

        var pos: usize = 0;
        const relation_id = readU32(data[pos .. pos + 4]);
        pos += 4;

        // Namespace (null-terminated string)
        const namespace_end = std.mem.findScalar(u8, data[pos..], 0) orelse return DecoderError.InvalidMessage;
        const namespace = self.allocator.dupe(u8, data[pos .. pos + namespace_end]) catch return DecoderError.OutOfMemory;
        errdefer self.allocator.free(namespace);
        pos += namespace_end + 1;

        // Relation name (null-terminated string)
        const relation_name_end = std.mem.findScalar(u8, data[pos..], 0) orelse return DecoderError.InvalidMessage;
        const relation_name = self.allocator.dupe(u8, data[pos .. pos + relation_name_end]) catch return DecoderError.OutOfMemory;
        errdefer self.allocator.free(relation_name);
        pos += relation_name_end + 1;

        if (pos >= data.len) return DecoderError.InvalidMessage;
        const replica_identity = data[pos];
        pos += 1;

        if (pos + 2 > data.len) return DecoderError.InvalidMessage;
        const column_count = readU16(data[pos .. pos + 2]);
        pos += 2;

        var columns = std.ArrayList(RelationMessageColumn).empty;
        errdefer {
            for (columns.items) |*col| {
                col.deinit(self.allocator);
            }
            columns.deinit(self.allocator);
        }

        var i: usize = 0;
        while (i < column_count) : (i += 1) {
            if (pos >= data.len) return DecoderError.InvalidMessage;
            const flags = data[pos];
            pos += 1;

            const col_name_end = std.mem.findScalar(u8, data[pos..], 0) orelse return DecoderError.InvalidMessage;
            const col_name = self.allocator.dupe(u8, data[pos .. pos + col_name_end]) catch return DecoderError.OutOfMemory;
            errdefer self.allocator.free(col_name);
            pos += col_name_end + 1;

            if (pos + 8 > data.len) return DecoderError.InvalidMessage;
            const data_type = readU32(data[pos .. pos + 4]);
            pos += 4;
            const type_modifier = readI32(data[pos .. pos + 4]);
            pos += 4;

            const column = RelationMessageColumn{
                .flags = flags,
                .name = col_name,
                .data_type = data_type,
                .type_modifier = type_modifier,
            };
            columns.append(self.allocator, column) catch return DecoderError.OutOfMemory;
        }

        return RelationMessage{
            .relation_id = relation_id,
            .namespace = namespace,
            .relation_name = relation_name,
            .replica_identity = replica_identity,
            .columns = columns.toOwnedSlice(self.allocator) catch return DecoderError.OutOfMemory,
        };
    }

    fn decodeTuple(self: *Self, data: []const u8, column_count: u16) DecoderError!struct { tuple: TupleMessage, bytes_read: usize } {
        var pos: usize = 0;
        var columns = std.ArrayList(TupleData).empty;
        errdefer {
            for (columns.items) |*col| {
                col.deinit(self.allocator);
            }
            columns.deinit(self.allocator);
        }

        var i: usize = 0;
        while (i < column_count) : (i += 1) {
            if (pos >= data.len) return DecoderError.InvalidTupleData;

            const col_type: TupleDataType = @enumFromInt(data[pos]);
            pos += 1;

            const tuple_data = switch (col_type) {
                .text, .binary => blk: {
                    if (pos + 4 > data.len) return DecoderError.InvalidTupleData;
                    const length = readU32(data[pos .. pos + 4]);
                    pos += 4;

                    if (pos + length > data.len) return DecoderError.InvalidTupleData;
                    const value = self.allocator.dupe(u8, data[pos .. pos + length]) catch return DecoderError.OutOfMemory;
                    pos += length;

                    break :blk TupleData{
                        .column_type = col_type,
                        .value = value,
                    };
                },
                .null, .unchanged_toast => TupleData{
                    .column_type = col_type,
                    .value = null,
                },
                else => return DecoderError.InvalidTupleData,
            };

            columns.append(self.allocator, tuple_data) catch return DecoderError.OutOfMemory;
        }

        return .{
            .tuple = TupleMessage{
                .columns = columns.toOwnedSlice(self.allocator) catch return DecoderError.OutOfMemory,
            },
            .bytes_read = pos,
        };
    }

    fn decodeInsert(self: *Self, data: []const u8) DecoderError!InsertMessage {
        if (data.len < 7) return DecoderError.InvalidMessage; // relation_id(4) + 'N'(1) + column_count(2)

        const relation_id = readU32(data[0..4]);

        if (data[4] != 'N') return DecoderError.InvalidMessage;

        const column_count = readU16(data[5..7]);

        const tuple_result = try self.decodeTuple(data[7..], column_count);

        return InsertMessage{
            .relation_id = relation_id,
            .new_tuple = tuple_result.tuple,
        };
    }

    fn decodeUpdate(self: *Self, data: []const u8) DecoderError!UpdateMessage {
        if (data.len < 5) return DecoderError.InvalidMessage;

        const relation_id = readU32(data[0..4]);
        var pos: usize = 4;

        const tuple_type = data[pos];
        pos += 1;

        var old_tuple: ?TupleMessage = null;
        if (tuple_type == 'O' or tuple_type == 'K') {
            const column_count = readU16(data[pos .. pos + 2]);
            pos += 2;

            const old_tuple_result = try self.decodeTuple(data[pos..], column_count);
            old_tuple = old_tuple_result.tuple;
            pos += old_tuple_result.bytes_read;

            if (pos >= data.len) return DecoderError.InvalidMessage;
            if (data[pos] != 'N') return DecoderError.InvalidMessage;
            pos += 1;
        } else if (tuple_type != 'N') {
            return DecoderError.InvalidMessage;
        }

        const new_column_count = readU16(data[pos .. pos + 2]);
        pos += 2;

        const new_tuple_result = try self.decodeTuple(data[pos..], new_column_count);

        return UpdateMessage{
            .relation_id = relation_id,
            .old_tuple = old_tuple,
            .new_tuple = new_tuple_result.tuple,
        };
    }

    fn decodeDelete(self: *Self, data: []const u8) DecoderError!DeleteMessage {
        if (data.len < 7) return DecoderError.InvalidMessage;

        const relation_id = readU32(data[0..4]);

        const tuple_type = data[4];
        if (tuple_type != 'O' and tuple_type != 'K') {
            return DecoderError.InvalidMessage;
        }

        const column_count = readU16(data[5..7]);

        const tuple_result = try self.decodeTuple(data[7..], column_count);

        return DeleteMessage{
            .relation_id = relation_id,
            .old_tuple = tuple_result.tuple,
        };
    }
};

// Helper functions for reading binary data (big-endian / network byte order)
fn readU64(bytes: []const u8) u64 {
    return (@as(u64, bytes[0]) << 56) |
        (@as(u64, bytes[1]) << 48) |
        (@as(u64, bytes[2]) << 40) |
        (@as(u64, bytes[3]) << 32) |
        (@as(u64, bytes[4]) << 24) |
        (@as(u64, bytes[5]) << 16) |
        (@as(u64, bytes[6]) << 8) |
        (@as(u64, bytes[7]));
}

fn readI64(bytes: []const u8) i64 {
    return @bitCast(readU64(bytes));
}

fn readU32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        (@as(u32, bytes[3]));
}

fn readI32(bytes: []const u8) i32 {
    return @bitCast(readU32(bytes));
}

fn readU16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) |
        (@as(u16, bytes[1]));
}

const testing = std.testing;

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

    var msg = try pg_decoder.decode(allocator, &data);
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

    var msg = try pg_decoder.decode(allocator, &data);
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

    var msg = try pg_decoder.decode(allocator, data.items);
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

    var msg = try pg_decoder.decode(allocator, data.items);
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

    var msg = try pg_decoder.decode(allocator, data.items);
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

    var msg = try pg_decoder.decode(allocator, data.items);
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

    var msg = try pg_decoder.decode(allocator, data.items);
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

    const result = pg_decoder.decode(allocator, &data);
    try testing.expectError(DecoderError.UnknownMessageType, result);
}

test "PgOutputDecoder: truncate, type and origin decode to skip" {
    const allocator = testing.allocator;
    var pg_decoder = PgOutputDecoder.init(allocator);

    // Only the leading type byte matters: the body is never parsed for these.
    for ([_]u8{ 'T', 'Y', 'O' }) |type_byte| {
        const data = [_]u8{ type_byte, 0xDE, 0xAD, 0xBE, 0xEF };
        var msg = try pg_decoder.decode(allocator, &data);
        defer msg.deinit(allocator);
        try testing.expect(msg == .skip);
    }
}

test "PgOutputDecoder: unchanged TOAST column decodes to null (no value sent)" {
    const allocator = testing.allocator;
    var pg_decoder = PgOutputDecoder.init(allocator);

    // UPDATE with a new-tuple-only body where the second column is an unchanged
    // TOAST ('u'): Postgres sends no value for it.
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);

    try data.append(allocator, 'U');

    var buf: [4]u8 = undefined;
    writeU32(&buf, 12345);
    try data.appendSlice(allocator, &buf);

    // 'N' = new tuple only
    try data.append(allocator, 'N');

    var col_count_buf: [2]u8 = undefined;
    writeU16(&col_count_buf, 2);
    try data.appendSlice(allocator, &col_count_buf);

    // Column 1: text value "42"
    try data.append(allocator, 't');
    writeU32(&buf, 2);
    try data.appendSlice(allocator, &buf);
    try data.appendSlice(allocator, "42");

    // Column 2: unchanged TOAST
    try data.append(allocator, 'u');

    var msg = try pg_decoder.decode(allocator, data.items);
    defer msg.deinit(allocator);

    try testing.expect(msg == .update);
    const cols = msg.update.new_tuple.columns;
    try testing.expectEqual(@as(usize, 2), cols.len);

    try testing.expect(cols[1].column_type == .unchanged_toast);
    try testing.expect(cols[1].value == null);
}
