const std = @import("std");
const testing = std.testing;
const test_helpers = @import("../testing/test_helpers.zig");

const Processor = @import("../processor/processor.zig").Processor;
const Observability = @import("../processor/processor.zig").Observability;
const PostgresSource = @import("../source/postgres/source.zig").PostgresSource;
const KafkaProducer = @import("../sink/kafka/producer.zig").KafkaProducer;
const Stream = @import("../config/config.zig").Stream;
const c = test_helpers.c;

// E2E Test: initial snapshot + streaming boundary
//
// Proves the #49 consistency contract end to end: rows that existed before the
// slot was created arrive as READ events (from the exported snapshot), the live
// changes made after streaming starts arrive as INSERT/UPDATE/DELETE, and the two
// phases meet with no gap or overlap. The READ rows carry the slot's start LSN,
// the same boundary the stream begins from. Running all three change operations
// past the boundary also proves the pipeline is fully wired after the phase
// switch, not just for the first change.

pub const std_options: std.Options = .{
    .log_level = .debug,
};

test "E2E: initial snapshot emits pre-existing rows as READ, then streams live changes" {
    const allocator = testing.allocator;

    const conn_str = try test_helpers.getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    const conn_str_z = try allocator.dupeZ(u8, conn_str);
    defer allocator.free(conn_str_z);

    const conn = c.PQconnectdb(conn_str_z.ptr) orelse return error.ConnectionFailed;
    defer c.PQfinish(conn);
    if (c.PQstatus(conn) != c.CONNECTION_OK) {
        std.log.err("PostgreSQL connection failed - E2E test requires PostgreSQL to be running", .{});
        return error.ConnectionFailed;
    }

    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "snap_e2e_{d}", .{timestamp});
    defer allocator.free(table_name);
    const topic_name = try std.fmt.allocPrint(allocator, "topic.snap.e2e.{d}", .{timestamp});
    defer allocator.free(topic_name);
    const slot_name = try std.fmt.allocPrint(allocator, "snap_e2e_slot_{d}", .{timestamp});
    defer allocator.free(slot_name);
    const pub_name = try std.fmt.allocPrint(allocator, "snap_e2e_pub_{d}", .{timestamp});
    defer allocator.free(pub_name);

    try test_helpers.createTestTable(conn, allocator, table_name);

    // Seed three rows BEFORE the slot exists, so they never enter the WAL stream;
    // only the snapshot can surface them.
    const seed = try test_helpers.formatSqlZ(allocator,
        \\INSERT INTO {s} (name, value) VALUES ('Alice', 100), ('Bob', 200), ('Carol', 300)
    , .{table_name});
    defer allocator.free(seed);
    _ = c.PQexec(conn, seed.ptr);

    // A stream that opts into the snapshot (read) and tracks every live operation.
    var stream_config = try test_helpers.createTestStreamConfig(allocator, table_name, topic_name);
    defer allocator.free(stream_config.name);
    defer allocator.free(stream_config.source.resource);
    stream_config.source.operations = &.{ "read", "insert", "update", "delete" };

    // NOTE: source will be deinit'd by processor.deinit().
    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer {
        const drop_slot = std.fmt.allocPrint(allocator, "SELECT pg_drop_replication_slot('{s}');", .{slot_name}) catch unreachable;
        defer allocator.free(drop_slot);
        const drop_slot_z = allocator.dupeZ(u8, drop_slot) catch unreachable;
        defer allocator.free(drop_slot_z);
        _ = c.PQexec(conn, drop_slot_z.ptr);
        // Streaming publication and the snapshot marker outboxx creates.
        const drop_pubs = std.fmt.allocPrintSentinel(allocator, "DROP PUBLICATION IF EXISTS {s}; DROP PUBLICATION IF EXISTS {s}_snapshotting;", .{ pub_name, slot_name }, 0) catch unreachable;
        defer allocator.free(drop_pubs);
        _ = c.PQexec(conn, drop_pubs.ptr);
    }

    // Create the slot without streaming; this exports the snapshot the reader binds
    // to. .with_snapshot also creates the snapshot marker publication.
    try source.connect(conn_str, .with_snapshot);
    const start_lsn = source.startLsn() orelse return error.NoConsistentPoint;
    try testing.expect(source.needsBootstrap()); // fresh slot exported a snapshot

    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = stream_config;

    var producer = try KafkaProducer.init(allocator, "localhost:9092", null);
    try producer.testConnection();

    var obs = Observability.noop();
    var processor = Processor.init(allocator, source, producer, streams, &obs);
    defer processor.deinit();

    var stop_signal = std.atomic.Value(bool).init(false);

    // Snapshot phase, which also opens the stream. The processor derives the read
    // resources from its streams and drives the snapshot through the source.
    try processor.bootstrap(std.testing.io, &stop_signal);

    // Live changes AFTER streaming started: they enter the WAL past the slot start,
    // so they must arrive as streamed events, not via the snapshot. All three
    // operations run, so the whole pipeline is exercised past the phase switch.
    const live = try test_helpers.formatSqlZ(allocator,
        \\INSERT INTO {s} (name, value) VALUES ('Dave', 400);
        \\UPDATE {s} SET value = 111 WHERE id = 1;
        \\DELETE FROM {s} WHERE id = 2;
    , .{ table_name, table_name, table_name });
    defer allocator.free(live);
    _ = c.PQexec(conn, live.ptr);
    test_helpers.sleepNs(std.testing.io, 200_000_000);

    var batch_arena = std.heap.ArenaAllocator.init(allocator);
    defer batch_arena.deinit();
    try processor.processChangesToKafka(std.testing.io, &stop_signal, batch_arena.allocator(), 100);

    const messages = try test_helpers.consumeAllMessages(std.testing.io, allocator, topic_name, 10000);
    defer test_helpers.cleanupJsonMessages(messages, allocator);

    // Three seeded rows as READ + the three live changes.
    try testing.expectEqual(@as(usize, 6), messages.len);

    var read_count: usize = 0;
    var seen_read_ids = [_]bool{false} ** 4; // ids 1..3

    for (messages[0..3]) |msg| {
        const id = msg.value.object.get("data").?.object.get("id").?.integer;

        try test_helpers.assertJsonField(msg, "op", "READ");
        // The dedup boundary: every READ row carries the slot's start LSN, the
        // point streaming then resumes from.
        try test_helpers.assertJsonField(msg, "meta.lsn", start_lsn);
        try test_helpers.assertJsonField(msg, "meta.resource", stream_config.source.resource);
        try testing.expect(id >= 1 and id <= 3); // seeded rows
        try testing.expect(!seen_read_ids[@intCast(id)]);
        seen_read_ids[@intCast(id)] = true;
        read_count += 1;
    }

    try testing.expectEqual(@as(usize, 3), read_count);
    // No gap, no overlap: the snapshot covered exactly the rows that predate the slot.
    for (1..4) |i| try testing.expect(seen_read_ids[i]);

    // Single-partition dev topic, so the log order is the produce order: the
    // snapshot ran to completion before the stream opened, and the live changes
    // follow in WAL order.
    try test_helpers.assertJsonField(messages[3], "op", "INSERT");
    try test_helpers.assertJsonField(messages[3], "data.name", "Dave");
    try testing.expectEqual(@as(i64, 4), messages[3].value.object.get("data").?.object.get("id").?.integer);

    try test_helpers.assertJsonField(messages[4], "op", "UPDATE");
    try testing.expectEqual(@as(i64, 1), messages[4].value.object.get("data").?.object.get("id").?.integer);
    try testing.expectEqual(@as(i64, 111), messages[4].value.object.get("data").?.object.get("value").?.integer);

    try test_helpers.assertJsonField(messages[5], "op", "DELETE");
    try testing.expectEqual(@as(i64, 2), messages[5].value.object.get("data").?.object.get("id").?.integer);
}
