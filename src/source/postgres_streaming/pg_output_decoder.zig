const std = @import("std");

pub const DecoderError = error{
    InvalidMessage,
    UnknownMessageType,
    OutOfMemory,
    InvalidTupleData,
};

// Message type identifiers from pgoutput protocol
pub const MessageType = enum(u8) {
    begin = 'B',
    commit = 'C',
    relation = 'R',
    insert = 'I',
    update = 'U',
    delete = 'D',
    origin = 'O',
    type = 'Y',
    truncate = 'T',
    _,
};

// Tuple column data type
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

pub const PgOutputMessage = union(enum) {
    begin: BeginMessage,
    commit: CommitMessage,
    relation: RelationMessage,
    insert: InsertMessage,
    update: UpdateMessage,
    delete: DeleteMessage,

    pub fn deinit(self: *PgOutputMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .begin, .commit => {},
            .relation => |*rel| rel.deinit(allocator),
            .insert => |*ins| ins.deinit(allocator),
            .update => |*upd| upd.deinit(allocator),
            .delete => |*del| del.deinit(allocator),
        }
    }
};

pub const PgOutputDecoder = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn decode(self: *Self, data: []const u8) DecoderError!PgOutputMessage {
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
            else => {
                std.log.debug("Unknown pgoutput message type: {c} (0x{x})", .{ @as(u8, @intFromEnum(msg_type)), @as(u8, @intFromEnum(msg_type)) });
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
        const namespace_end = std.mem.indexOfScalar(u8, data[pos..], 0) orelse return DecoderError.InvalidMessage;
        const namespace = self.allocator.dupe(u8, data[pos .. pos + namespace_end]) catch return DecoderError.OutOfMemory;
        errdefer self.allocator.free(namespace);
        pos += namespace_end + 1;

        // Relation name (null-terminated string)
        const relation_name_end = std.mem.indexOfScalar(u8, data[pos..], 0) orelse return DecoderError.InvalidMessage;
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

            const col_name_end = std.mem.indexOfScalar(u8, data[pos..], 0) orelse return DecoderError.InvalidMessage;
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
                .null, .unchanged_toast => TupleData{
                    .column_type = col_type,
                    .value = null,
                },
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
