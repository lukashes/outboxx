const std = @import("std");
const zbench = @import("zbench");
const postgres_source = @import("../../../src/source/postgres/source.zig");
const bench_helpers = @import("../bench_helpers.zig");

const PgOutputMessage = postgres_source.PgOutputMessage;
const InsertMessage = postgres_source.InsertMessage;
const UpdateMessage = postgres_source.UpdateMessage;
const DeleteMessage = postgres_source.DeleteMessage;
const TupleMessage = postgres_source.TupleMessage;
const TupleData = postgres_source.TupleData;
const RelationMessage = postgres_source.RelationMessage;
const RelationMessageColumn = postgres_source.RelationMessageColumn;
const Converter = postgres_source.Converter;
const CountingAllocator = bench_helpers.CountingAllocator;

const iterations = 100000;

fn setupConverter(allocator: std.mem.Allocator) !Converter {
    var converter = Converter.init(allocator);
    errdefer converter.deinit();

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
    defer rel_msg.deinit(allocator);

    _ = try converter.convert(allocator, .{ .relation = rel_msg }, 0);
    return converter;
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

// Converter.convert allocates the event per run (tracked). The registry is
// populated once in setup, outside the measured loop.
const BenchConvertInsert = struct {
    converter: *Converter,
    message: PgOutputMessage,

    pub fn run(self: *BenchConvertInsert, allocator: std.mem.Allocator) void {
        var event = (self.converter.convert(allocator, self.message, 0) catch unreachable).?;
        event.deinit(allocator);
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

const BenchConvertUpdate = struct {
    converter: *Converter,
    message: PgOutputMessage,

    pub fn run(self: *BenchConvertUpdate, allocator: std.mem.Allocator) void {
        var event = (self.converter.convert(allocator, self.message, 0) catch unreachable).?;
        event.deinit(allocator);
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

const BenchConvertDelete = struct {
    converter: *Converter,
    message: PgOutputMessage,

    pub fn run(self: *BenchConvertDelete, allocator: std.mem.Allocator) void {
        var event = (self.converter.convert(allocator, self.message, 0) catch unreachable).?;
        event.deinit(allocator);
    }
};

test "benchmark Converter INSERT" {
    var insert_msg = try buildInsertMessage(std.testing.allocator);
    defer insert_msg.deinit(std.testing.allocator);

    var converter = try setupConverter(std.testing.allocator);
    defer converter.deinit();

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const insert_pg_msg = PgOutputMessage{ .insert = insert_msg };

    const bench_insert = BenchConvertInsert{
        .converter = &converter,
        .message = insert_pg_msg,
    };

    try bench.addParam("Converter.convert (INSERT)", &bench_insert, .{
        .iterations = iterations,
        .track_allocations = true,
    });

    try bench.run(std.testing.io, std.Io.File.stdout());

    const allocations_per_iter = alloc_count / iterations;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}

test "benchmark Converter UPDATE" {
    var update_msg = try buildUpdateMessage(std.testing.allocator);
    defer update_msg.deinit(std.testing.allocator);

    var converter = try setupConverter(std.testing.allocator);
    defer converter.deinit();

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const update_pg_msg = PgOutputMessage{ .update = update_msg };

    const bench_update = BenchConvertUpdate{
        .converter = &converter,
        .message = update_pg_msg,
    };

    try bench.addParam("Converter.convert (UPDATE)", &bench_update, .{
        .iterations = iterations,
        .track_allocations = true,
    });

    try bench.run(std.testing.io, std.Io.File.stdout());

    const allocations_per_iter = alloc_count / iterations;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}

test "benchmark Converter DELETE" {
    var delete_msg = try buildDeleteMessage(std.testing.allocator);
    defer delete_msg.old_tuple.deinit(std.testing.allocator);

    var converter = try setupConverter(std.testing.allocator);
    defer converter.deinit();

    var alloc_count: usize = 0;
    var counting_alloc = CountingAllocator{
        .parent_allocator = std.testing.allocator,
        .allocation_count = &alloc_count,
    };

    var bench = zbench.Benchmark.init(counting_alloc.allocator(), .{});
    defer bench.deinit();

    alloc_count = 0;

    const delete_pg_msg = PgOutputMessage{ .delete = delete_msg };

    const bench_delete = BenchConvertDelete{
        .converter = &converter,
        .message = delete_pg_msg,
    };

    try bench.addParam("Converter.convert (DELETE)", &bench_delete, .{
        .iterations = iterations,
        .track_allocations = true,
    });

    try bench.run(std.testing.io, std.Io.File.stdout());

    const allocations_per_iter = alloc_count / iterations;
    std.debug.print("\nAllocations per operation: {d}\n", .{allocations_per_iter});
}
