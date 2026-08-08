const std = @import("std");
const testing = std.testing;
const test_helpers = @import("../testing/test_helpers.zig");

const Processor = @import("processor.zig").Processor;
const Observability = @import("processor.zig").Observability;
const PostgresSource = @import("../source/postgres/source.zig").PostgresSource;
const KafkaProducer = @import("../sink/kafka/producer.zig").KafkaProducer;
const Stream = @import("../config/config.zig").Stream;
const c = test_helpers.c;

// The snapshot resource set is derived from the streams, and that derivation
// (Processor.readResources) is the one snapshot step with no source-level
// counterpart to test: it decides which tables are read and how many times.
// The matrix below is the one that can go wrong: two streams sharing a resource
// must not read it twice, and a stream without `read` must not be snapshotted at
// all even though it sits in the same publication.

test "Processor.bootstrap: reads a shared resource once and skips streams without read" {
    const allocator = testing.allocator;

    const conn_str = try test_helpers.getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    const conn_str_z = try allocator.dupeZ(u8, conn_str);
    defer allocator.free(conn_str_z);

    const conn = c.PQconnectdb(conn_str_z.ptr) orelse return error.ConnectionFailed;
    defer c.PQfinish(conn);
    if (c.PQstatus(conn) != c.CONNECTION_OK) {
        std.log.err("PostgreSQL connection failed - integration test requires PostgreSQL to be running", .{});
        return error.ConnectionFailed;
    }

    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_read = try std.fmt.allocPrint(allocator, "snap_fanout_{d}", .{timestamp});
    defer allocator.free(table_read);
    const table_plain = try std.fmt.allocPrint(allocator, "snap_noread_{d}", .{timestamp});
    defer allocator.free(table_plain);
    const slot_name = try std.fmt.allocPrint(allocator, "snap_fanout_slot_{d}", .{timestamp});
    defer allocator.free(slot_name);
    const pub_name = try std.fmt.allocPrint(allocator, "snap_fanout_pub_{d}", .{timestamp});
    defer allocator.free(pub_name);

    // Two topics for the read table, so a resource shared by two streams shows up
    // as a fan-out rather than as a second read.
    const topic_primary = try std.fmt.allocPrint(allocator, "topic.snap.fanout.primary.{d}", .{timestamp});
    defer allocator.free(topic_primary);
    const topic_mirror = try std.fmt.allocPrint(allocator, "topic.snap.fanout.mirror.{d}", .{timestamp});
    defer allocator.free(topic_mirror);
    const topic_plain = try std.fmt.allocPrint(allocator, "topic.snap.fanout.noread.{d}", .{timestamp});
    defer allocator.free(topic_plain);

    try test_helpers.createTestTable(conn, allocator, table_read);
    try test_helpers.createTestTable(conn, allocator, table_plain);

    // Both tables are seeded before the slot exists, so anything that reaches Kafka
    // from them can only have come through the snapshot.
    const seed = try test_helpers.formatSqlZ(allocator,
        \\INSERT INTO {s} (name, value) VALUES ('Alice', 100), ('Bob', 200);
        \\INSERT INTO {s} (name, value) VALUES ('Carol', 300), ('Dave', 400);
    , .{ table_read, table_plain });
    defer allocator.free(seed);
    _ = c.PQexec(conn, seed.ptr);

    var stream_primary = try test_helpers.createTestStreamConfig(allocator, table_read, topic_primary);
    defer allocator.free(stream_primary.name);
    defer allocator.free(stream_primary.source.resource);
    stream_primary.source.operations = &.{ "read", "insert" };

    var stream_mirror = try test_helpers.createTestStreamConfig(allocator, table_read, topic_mirror);
    defer allocator.free(stream_mirror.name);
    defer allocator.free(stream_mirror.source.resource);
    stream_mirror.source.operations = &.{"read"};

    var stream_plain = try test_helpers.createTestStreamConfig(allocator, table_plain, topic_plain);
    defer allocator.free(stream_plain.name);
    defer allocator.free(stream_plain.source.resource);
    stream_plain.source.operations = &.{"insert"};

    // NOTE: source will be deinit'd by processor.deinit().
    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer {
        const drop_slot = std.fmt.allocPrintSentinel(allocator, "SELECT pg_drop_replication_slot('{s}');", .{slot_name}, 0) catch unreachable;
        defer allocator.free(drop_slot);
        _ = c.PQexec(conn, drop_slot.ptr);
        const drop_pubs = std.fmt.allocPrintSentinel(allocator, "DROP PUBLICATION IF EXISTS {s}; DROP PUBLICATION IF EXISTS {s}_snapshotting;", .{ pub_name, slot_name }, 0) catch unreachable;
        defer allocator.free(drop_pubs);
        _ = c.PQexec(conn, drop_pubs.ptr);
        const drop_tables = std.fmt.allocPrintSentinel(allocator, "DROP TABLE IF EXISTS {s}; DROP TABLE IF EXISTS {s};", .{ table_read, table_plain }, 0) catch unreachable;
        defer allocator.free(drop_tables);
        _ = c.PQexec(conn, drop_tables.ptr);
    }

    try source.connect(conn_str, .with_snapshot);
    try testing.expect(source.needsBootstrap());

    const streams = try allocator.alloc(Stream, 3);
    defer allocator.free(streams);
    streams[0] = stream_primary;
    streams[1] = stream_mirror;
    streams[2] = stream_plain;

    var producer = try KafkaProducer.init(allocator, "localhost:9092", null);
    try producer.testConnection();

    var obs = Observability.noop();
    var processor = Processor.init(allocator, source, producer, streams, &obs);
    defer processor.deinit();

    var stop_signal = std.atomic.Value(bool).init(false);
    try processor.bootstrap(std.testing.io, &stop_signal);

    // A live change on the read-less table: it must still stream, so the missing
    // `read` is proven to skip the snapshot rather than the stream.
    const live = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Erin', 500)", .{table_plain});
    defer allocator.free(live);
    _ = c.PQexec(conn, live.ptr);
    test_helpers.sleepNs(std.testing.io, 200_000_000);

    var batch_arena = std.heap.ArenaAllocator.init(allocator);
    defer batch_arena.deinit();
    try processor.processChangesToKafka(std.testing.io, &stop_signal, batch_arena.allocator(), 100);

    const primary = try test_helpers.consumeAllMessages(std.testing.io, allocator, topic_primary, 10000);
    defer test_helpers.cleanupJsonMessages(primary, allocator);
    const mirror = try test_helpers.consumeAllMessages(std.testing.io, allocator, topic_mirror, 10000);
    defer test_helpers.cleanupJsonMessages(mirror, allocator);
    const plain = try test_helpers.consumeAllMessages(std.testing.io, allocator, topic_plain, 10000);
    defer test_helpers.cleanupJsonMessages(plain, allocator);

    // Read once, delivered twice: each topic gets both rows exactly once, so the
    // shared resource was not snapshotted per stream.
    try testing.expectEqual(@as(usize, 2), primary.len);
    try testing.expectEqual(@as(usize, 2), mirror.len);
    for (primary) |msg| try test_helpers.assertJsonField(msg, "op", "READ");
    for (mirror) |msg| try test_helpers.assertJsonField(msg, "op", "READ");
    for (primary) |msg| try test_helpers.assertJsonField(msg, "meta.resource", stream_primary.source.resource);

    // No `read`, so the seeded rows never appear: only the live insert does.
    try testing.expectEqual(@as(usize, 1), plain.len);
    try test_helpers.assertJsonField(plain[0], "op", "INSERT");
    try test_helpers.assertJsonField(plain[0], "data.name", "Erin");
}
