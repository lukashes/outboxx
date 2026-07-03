const std = @import("std");
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;

const pg_output_decoder = @import("pg_output_decoder.zig");
const PgOutputMessage = pg_output_decoder.PgOutputMessage;

const relation_registry = @import("relation_registry.zig");
const RelationRegistry = relation_registry.RelationRegistry;

const converter = @import("converter.zig");

pub const ProcessError = error{ConversionFailed};

/// Turns decoded pgoutput messages into domain ChangeEvents.
///
/// The consumer side of the source: it keeps the relation registry up to date
/// (RELATION messages) and delegates value conversion to the converter. Owns the
/// registry, so relation state lives with the component that maintains it. Does no
/// I/O, which is what will let it run on a worker thread draining a buffer later.
/// Returns null for messages that carry no change (BEGIN, COMMIT, RELATION).
pub const MessageProcessor = struct {
    registry: RelationRegistry,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .registry = RelationRegistry.init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit();
    }

    pub fn process(self: *Self, io: std.Io, allocator: std.mem.Allocator, pg_msg: PgOutputMessage) ProcessError!?ChangeEvent {
        switch (pg_msg) {
            .begin, .commit => return null,
            .relation => |rel| {
                self.registry.register(rel) catch |err| {
                    std.log.warn("Failed to register relation: {}", .{err});
                    return ProcessError.ConversionFailed;
                };
                return null;
            },
            .insert => |ins| return converter.convertInsert(io, allocator, ins, &self.registry) catch |err| {
                std.log.warn("Failed to convert INSERT: {}", .{err});
                return ProcessError.ConversionFailed;
            },
            .update => |upd| return converter.convertUpdate(io, allocator, upd, &self.registry) catch |err| {
                std.log.warn("Failed to convert UPDATE: {}", .{err});
                return ProcessError.ConversionFailed;
            },
            .delete => |del| return converter.convertDelete(io, allocator, del, &self.registry) catch |err| {
                std.log.warn("Failed to convert DELETE: {}", .{err});
                return ProcessError.ConversionFailed;
            },
        }
    }
};

const testing = std.testing;

test "process: relation registers then insert converts" {
    const allocator = testing.allocator;

    var mp = MessageProcessor.init(allocator);
    defer mp.deinit();

    // RELATION registers the schema and yields no event.
    var rel = pg_output_decoder.RelationMessage{
        .relation_id = 100,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 2),
    };
    rel.columns[0] = .{ .flags = 1, .name = try allocator.dupe(u8, "id"), .data_type = 23, .type_modifier = -1 };
    rel.columns[1] = .{ .flags = 0, .name = try allocator.dupe(u8, "name"), .data_type = 25, .type_modifier = -1 };
    var rel_msg = PgOutputMessage{ .relation = rel };
    defer rel_msg.deinit(allocator);

    try testing.expect((try mp.process(std.testing.io, allocator, rel_msg)) == null);

    // INSERT for the registered relation converts to a ChangeEvent.
    var ins = pg_output_decoder.InsertMessage{
        .relation_id = 100,
        .new_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 2),
        },
    };
    ins.new_tuple.columns[0] = .{ .column_type = .text, .value = try allocator.dupe(u8, "1") };
    ins.new_tuple.columns[1] = .{ .column_type = .text, .value = try allocator.dupe(u8, "Alice") };
    var ins_msg = PgOutputMessage{ .insert = ins };
    defer ins_msg.deinit(allocator);

    var event = (try mp.process(std.testing.io, allocator, ins_msg)).?;
    defer event.deinit(allocator);

    try testing.expectEqualStrings("INSERT", event.op);
    try testing.expect(event.data == .insert);
    try testing.expectEqual(@as(i64, 1), event.data.insert[0].value.integer);
    try testing.expectEqualStrings("Alice", event.data.insert[1].value.string);
}

test "process: begin and commit yield no event" {
    const allocator = testing.allocator;

    var mp = MessageProcessor.init(allocator);
    defer mp.deinit();

    var begin = PgOutputMessage{ .begin = .{ .final_lsn = 0, .commit_time = 0, .xid = 1 } };
    defer begin.deinit(allocator);
    try testing.expect((try mp.process(std.testing.io, allocator, begin)) == null);

    var commit = PgOutputMessage{ .commit = .{ .flags = 0, .commit_lsn = 0, .end_lsn = 0, .commit_time = 0 } };
    defer commit.deinit(allocator);
    try testing.expect((try mp.process(std.testing.io, allocator, commit)) == null);
}
