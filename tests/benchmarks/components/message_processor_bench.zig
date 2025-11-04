const std = @import("std");
const zbench = @import("zbench");
const postgres_source = @import("postgres_source");
const bench_helpers = @import("bench_helpers");

// Import all types from postgres_source (re-exported)
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

var global_registry: ?RelationRegistry = null;
var global_processor: ?MessageProcessor = null;

fn setupRegistry(allocator: std.mem.Allocator) !void {
    global_registry = RelationRegistry.init(allocator);

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

    try global_registry.?.register(rel_msg);
}

fn benchmarkInsertMessage(allocator: std.mem.Allocator) void {
    var insert_msg = InsertMessage{
        .relation_id = 100,
        .new_tuple = TupleMessage{
            .columns = allocator.alloc(TupleData, 4) catch unreachable,
        },
    };
    defer insert_msg.new_tuple.deinit(allocator);

    insert_msg.new_tuple.columns[0] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "12345") catch unreachable,
    };
    insert_msg.new_tuple.columns[1] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "Alice") catch unreachable,
    };
    insert_msg.new_tuple.columns[2] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "alice@example.com") catch unreachable,
    };
    insert_msg.new_tuple.columns[3] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "true") catch unreachable,
    };

    const pg_msg = PgOutputMessage{ .insert = insert_msg };

    var event = global_processor.?.processMessage(pg_msg, &global_registry.?) catch unreachable;
    if (event) |*e| {
        e.deinit(allocator);
    }
}

fn benchmarkUpdateMessage(allocator: std.mem.Allocator) void {
    var update_msg = UpdateMessage{
        .relation_id = 100,
        .old_tuple = TupleMessage{
            .columns = allocator.alloc(TupleData, 4) catch unreachable,
        },
        .new_tuple = TupleMessage{
            .columns = allocator.alloc(TupleData, 4) catch unreachable,
        },
    };
    defer update_msg.deinit(allocator);

    // Old tuple
    update_msg.old_tuple.?.columns[0] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "12345") catch unreachable,
    };
    update_msg.old_tuple.?.columns[1] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "Alice") catch unreachable,
    };
    update_msg.old_tuple.?.columns[2] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "alice@example.com") catch unreachable,
    };
    update_msg.old_tuple.?.columns[3] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "true") catch unreachable,
    };

    // New tuple
    update_msg.new_tuple.columns[0] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "12345") catch unreachable,
    };
    update_msg.new_tuple.columns[1] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "Bob") catch unreachable,
    };
    update_msg.new_tuple.columns[2] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "bob@example.com") catch unreachable,
    };
    update_msg.new_tuple.columns[3] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "false") catch unreachable,
    };

    const pg_msg = PgOutputMessage{ .update = update_msg };

    var event = global_processor.?.processMessage(pg_msg, &global_registry.?) catch unreachable;
    if (event) |*e| {
        e.deinit(allocator);
    }
}

fn benchmarkDeleteMessage(allocator: std.mem.Allocator) void {
    var delete_msg = DeleteMessage{
        .relation_id = 100,
        .old_tuple = TupleMessage{
            .columns = allocator.alloc(TupleData, 4) catch unreachable,
        },
    };
    defer delete_msg.old_tuple.deinit(allocator);

    delete_msg.old_tuple.columns[0] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "12345") catch unreachable,
    };
    delete_msg.old_tuple.columns[1] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "Alice") catch unreachable,
    };
    delete_msg.old_tuple.columns[2] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "alice@example.com") catch unreachable,
    };
    delete_msg.old_tuple.columns[3] = TupleData{
        .column_type = .text,
        .value = allocator.dupe(u8, "true") catch unreachable,
    };

    const pg_msg = PgOutputMessage{ .delete = delete_msg };

    var event = global_processor.?.processMessage(pg_msg, &global_registry.?) catch unreachable;
    if (event) |*e| {
        e.deinit(allocator);
    }
}

test "benchmark MessageProcessor" {
    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    // Setup: create registry and processor once
    try setupRegistry(counting_alloc.allocator());
    defer {
        if (global_registry) |*registry| {
            registry.deinit();
        }
    }

    global_processor = MessageProcessor.init(counting_alloc.allocator());

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    // Reset allocation counter after all setup
    alloc_count = 0;

    try bench.add("MessageProcessor.processMessage (INSERT)", benchmarkInsertMessage, .{
        .iterations = 1000,
        .track_allocations = true,
    });

    try bench.add("MessageProcessor.processMessage (UPDATE)", benchmarkUpdateMessage, .{
        .iterations = 1000,
        .track_allocations = true,
    });

    try bench.add("MessageProcessor.processMessage (DELETE)", benchmarkDeleteMessage, .{
        .iterations = 1000,
        .track_allocations = true,
    });

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try bench.run(writer);
    try writer.flush();

    const allocations_per_iter = alloc_count / 3000;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}
