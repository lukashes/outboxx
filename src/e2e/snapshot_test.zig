const std = @import("std");
const testing = std.testing;
const test_helpers = @import("../testing/test_helpers.zig");

const Processor = @import("../processor/processor.zig").Processor;
const Observability = @import("../processor/processor.zig").Observability;
const PostgresSource = @import("../source/postgres/source.zig").PostgresSource;
const SnapshotReader = @import("../source/postgres/snapshot.zig").SnapshotReader;
const KafkaProducer = @import("../sink/kafka/producer.zig").KafkaProducer;
const Stream = @import("../config/config.zig").Stream;
const c = test_helpers.c;

// E2E Test: initial snapshot + streaming boundary
//
// Proves the #49 consistency contract end to end: rows that existed before the
// slot was created arrive as READ events (from the exported snapshot), a row
// inserted after streaming starts arrives as an INSERT, and the two meet with no
// gap or overlap. The READ rows carry the slot's start LSN, the same boundary the
// stream begins from.

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

    // A stream that opts into the snapshot (read) and also tracks live inserts.
    var stream_config = try test_helpers.createTestStreamConfig(allocator, table_name, topic_name);
    defer allocator.free(stream_config.name);
    defer allocator.free(stream_config.source.resource);
    stream_config.source.operations = &.{ "read", "insert" };

    // NOTE: source will be deinit'd by processor.deinit().
    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer {
        const drop_slot = std.fmt.allocPrint(allocator, "SELECT pg_drop_replication_slot('{s}');", .{slot_name}) catch unreachable;
        defer allocator.free(drop_slot);
        const drop_slot_z = allocator.dupeZ(u8, drop_slot) catch unreachable;
        defer allocator.free(drop_slot_z);
        _ = c.PQexec(conn, drop_slot_z.ptr);
    }

    // Create the slot without streaming; this exports the snapshot the reader binds to.
    try source.connect(conn_str);
    const start_lsn = source.startLsn() orelse return error.NoConsistentPoint;
    const snapshot_name = source.snapshotName() orelse return error.NoExportedSnapshot;

    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = stream_config;

    var producer = try KafkaProducer.init(allocator, "localhost:9092", null);
    try producer.testConnection();

    var obs = Observability.noop();
    var processor = Processor.init(allocator, source, producer, streams, &obs);
    defer processor.deinit();

    var stop_signal = std.atomic.Value(bool).init(false);

    // Run the snapshot, then start streaming from the slot's start LSN.
    {
        const snap_ts = test_helpers.nowSeconds(std.testing.io);
        var reader = SnapshotReader.init(allocator, snapshot_name, start_lsn, snap_ts);
        defer reader.deinit();
        try reader.connect(conn_str);

        const resources = [_][]const u8{stream_config.source.resource};
        try processor.runInitialSnapshot(&reader, &resources, &stop_signal);
    }

    try processor.beginReplication(start_lsn);

    // A live insert AFTER streaming started: it enters the WAL past the slot start,
    // so it must arrive as a streamed INSERT, not via the snapshot.
    const live = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Dave', 400)", .{table_name});
    defer allocator.free(live);
    _ = c.PQexec(conn, live.ptr);
    test_helpers.sleepNs(std.testing.io, 200_000_000);

    var batch_arena = std.heap.ArenaAllocator.init(allocator);
    defer batch_arena.deinit();
    try processor.processChangesToKafka(std.testing.io, &stop_signal, batch_arena.allocator(), 100);

    const messages = try test_helpers.consumeAllMessages(std.testing.io, allocator, topic_name, 10000);
    defer test_helpers.cleanupJsonMessages(messages, allocator);

    // Three seeded rows as READ + one live row as INSERT.
    try testing.expectEqual(@as(usize, 4), messages.len);

    var read_count: usize = 0;
    var insert_count: usize = 0;
    var seen_ids = [_]bool{false} ** 5; // ids 1..4

    for (messages) |msg| {
        const op = msg.value.object.get("op").?.string;
        const data = msg.value.object.get("data").?.object;
        const id = data.get("id").?.integer;

        if (std.mem.eql(u8, op, "READ")) {
            read_count += 1;
            // The dedup boundary: every READ row carries the slot's start LSN, the
            // point streaming then resumes from.
            try test_helpers.assertJsonField(msg, "meta.lsn", start_lsn);
            try test_helpers.assertJsonField(msg, "meta.resource", stream_config.source.resource);
            try testing.expect(id >= 1 and id <= 3); // seeded rows
        } else if (std.mem.eql(u8, op, "INSERT")) {
            insert_count += 1;
            try test_helpers.assertJsonField(msg, "data.name", "Dave");
            try testing.expectEqual(@as(i64, 4), id); // the live row, not in the snapshot
        }
        try testing.expect(!seen_ids[@intCast(id)]);
        seen_ids[@intCast(id)] = true;
    }

    try testing.expectEqual(@as(usize, 3), read_count);
    try testing.expectEqual(@as(usize, 1), insert_count);

    // No gap, no overlap: the snapshot covered ids 1..3, the stream covered id 4.
    for (1..5) |i| try testing.expect(seen_ids[i]);

    // Single-partition dev topic: the snapshot rows were produced before the live
    // insert, so they precede it in the log.
    try test_helpers.assertJsonField(messages[messages.len - 1], "op", "INSERT");
}
