const std = @import("std");
const zbench = @import("zbench");
const postgres_source = @import("postgres_source");
const bench_helpers = @import("bench_helpers");

const MessageProcessor = postgres_source.MessageProcessor;
const PgOutputMessage = postgres_source.PgOutputMessage;
const InsertMessage = postgres_source.InsertMessage;
const UpdateMessage = postgres_source.UpdateMessage;
const DeleteMessage = postgres_source.DeleteMessage;
const TupleMessage = postgres_source.TupleMessage;
const TupleData = postgres_source.TupleData;
const RelationMessage = postgres_source.RelationMessage;
const RelationMessageColumn = postgres_source.RelationMessageColumn;
const RelationRegistry = postgres_source.RelationRegistry;
const CountingAllocator = bench_helpers.CountingAllocator;

const iterations = 100000;

fn setupRegistry(allocator: std.mem.Allocator) !RelationRegistry {
    var registry = RelationRegistry.init(allocator);

    // Register test relation (id=100, public.users, columns: id, name, email, active)
    var rel_msg = RelationMessage{
        .relation_id = 100,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(RelationMessageColumn, 4),
    };

    rel_msg.columns[0] = RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23, // int4
        .type_modifier = -1,
    };
    rel_msg.columns[1] = RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25, // text
        .type_modifier = -1,
    };
    rel_msg.columns[2] = RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "email"),
        .data_type = 25, // text
        .type_modifier = -1,
    };
    rel_msg.columns[3] = RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "active"),
        .data_type = 16, // bool
        .type_modifier = -1,
    };

    try registry.register(rel_msg);
    return registry;
}

fn buildInsertMessage(allocator: std.mem.Allocator) !InsertMessage {
    var insert_msg = InsertMessage{
        .relation_id = 100,
        .new_tuple = TupleMessage{
            .columns = try allocator.alloc(TupleData, 4),
        },
    };

    insert_msg.new_tuple.columns[0] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "12345"),
    };
    insert_msg.new_tuple.columns[1] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Alice"),
    };
    insert_msg.new_tuple.columns[2] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "alice@example.com"),
    };
    insert_msg.new_tuple.columns[3] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "true"),
    };

    return insert_msg;
}

// MessageProcessor.init() is lightweight (no allocations), created inside to track processMessage() allocations.
// RelationRegistry setup is heavy (table registration), prepared outside
const BenchProcessInsert = struct {
    registry: *RelationRegistry,
    message: PgOutputMessage,

    pub fn run(self: BenchProcessInsert, allocator: std.mem.Allocator) void {
        var processor = MessageProcessor.init(allocator);
        var event = processor.processMessage(self.message, self.registry) catch unreachable;
        if (event) |*e| {
            e.deinit(allocator);
        }
    }
};

fn buildUpdateMessage(allocator: std.mem.Allocator) !UpdateMessage {
    var update_msg = UpdateMessage{
        .relation_id = 100,
        .old_tuple = TupleMessage{
            .columns = try allocator.alloc(TupleData, 4),
        },
        .new_tuple = TupleMessage{
            .columns = try allocator.alloc(TupleData, 4),
        },
    };

    update_msg.old_tuple.?.columns[0] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "12345"),
    };
    update_msg.old_tuple.?.columns[1] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Alice"),
    };
    update_msg.old_tuple.?.columns[2] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "alice@example.com"),
    };
    update_msg.old_tuple.?.columns[3] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "true"),
    };

    update_msg.new_tuple.columns[0] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "12345"),
    };
    update_msg.new_tuple.columns[1] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Bob"),
    };
    update_msg.new_tuple.columns[2] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "bob@example.com"),
    };
    update_msg.new_tuple.columns[3] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "false"),
    };

    return update_msg;
}

const BenchProcessUpdate = struct {
    registry: *RelationRegistry,
    message: PgOutputMessage,

    pub fn run(self: BenchProcessUpdate, allocator: std.mem.Allocator) void {
        var processor = MessageProcessor.init(allocator);
        var event = processor.processMessage(self.message, self.registry) catch unreachable;
        if (event) |*e| {
            e.deinit(allocator);
        }
    }
};

fn buildDeleteMessage(allocator: std.mem.Allocator) !DeleteMessage {
    var delete_msg = DeleteMessage{
        .relation_id = 100,
        .old_tuple = TupleMessage{
            .columns = try allocator.alloc(TupleData, 4),
        },
    };

    delete_msg.old_tuple.columns[0] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "12345"),
    };
    delete_msg.old_tuple.columns[1] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Alice"),
    };
    delete_msg.old_tuple.columns[2] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "alice@example.com"),
    };
    delete_msg.old_tuple.columns[3] = TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "true"),
    };

    return delete_msg;
}

const BenchProcessDelete = struct {
    registry: *RelationRegistry,
    message: PgOutputMessage,

    pub fn run(self: BenchProcessDelete, allocator: std.mem.Allocator) void {
        var processor = MessageProcessor.init(allocator);
        var event = processor.processMessage(self.message, self.registry) catch unreachable;
        if (event) |*e| {
            e.deinit(allocator);
        }
    }
};

test "benchmark MessageProcessor INSERT" {
    var insert_msg = try buildInsertMessage(std.testing.allocator);
    defer insert_msg.deinit(std.testing.allocator);

    var registry = try setupRegistry(std.testing.allocator);
    defer registry.deinit();

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const insert_pg_msg = PgOutputMessage{ .insert = insert_msg };

    const bench_insert = BenchProcessInsert{
        .registry = &registry,
        .message = insert_pg_msg,
    };

    try bench.addParam("MessageProcessor.processMessage (INSERT)", &bench_insert, .{
        .iterations = iterations,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / iterations;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}

test "benchmark MessageProcessor UPDATE" {
    var update_msg = try buildUpdateMessage(std.testing.allocator);
    defer update_msg.deinit(std.testing.allocator);

    var registry = try setupRegistry(std.testing.allocator);
    defer registry.deinit();

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const update_pg_msg = PgOutputMessage{ .update = update_msg };

    const bench_update = BenchProcessUpdate{
        .registry = &registry,
        .message = update_pg_msg,
    };

    try bench.addParam("MessageProcessor.processMessage (UPDATE)", &bench_update, .{
        .iterations = iterations,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / iterations;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}

test "benchmark MessageProcessor DELETE" {
    var delete_msg = try buildDeleteMessage(std.testing.allocator);
    defer delete_msg.old_tuple.deinit(std.testing.allocator);

    var registry = try setupRegistry(std.testing.allocator);
    defer registry.deinit();

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const delete_pg_msg = PgOutputMessage{ .delete = delete_msg };

    const bench_delete = BenchProcessDelete{
        .registry = &registry,
        .message = delete_pg_msg,
    };

    try bench.addParam("MessageProcessor.processMessage (DELETE)", &bench_delete, .{
        .iterations = iterations,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / iterations;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}
