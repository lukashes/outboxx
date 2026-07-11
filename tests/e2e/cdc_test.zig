const std = @import("std");
const testing = std.testing;
const test_helpers = @import("test_helpers");

const Processor = @import("cdc_processor").Processor;
const Observability = @import("cdc_processor").Observability;
const PostgresSource = @import("postgres_source").PostgresSource;
const KafkaProducer = @import("kafka_producer").KafkaProducer;
const Stream = @import("config").Stream;
const c = test_helpers.c;

// E2E Test: CDC Pipeline Verification
// Tests the complete flow: PostgreSQL → CDC Processor → Kafka
//
// Principle: Black box testing
// - Input: SQL operations in PostgreSQL
// - Output: JSON messages in Kafka
// - Verification: Message count matches change count, JSON structure is correct

// Enable debug logging for these tests
pub const std_options: std.Options = .{
    .log_level = .debug,
};

test "E2E: INSERT operation - full pipeline verification" {
    const allocator = testing.allocator;

    // Setup PostgreSQL connection
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

    // Test configuration with unique names to avoid cross-test contamination
    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "users_stream_insert_{d}", .{timestamp});
    defer allocator.free(table_name);
    const topic_name = try std.fmt.allocPrint(allocator, "topic.stream.insert.{d}", .{timestamp});
    defer allocator.free(topic_name);
    const slot_name = try std.fmt.allocPrint(allocator, "e2e_stream_insert_slot_{d}", .{timestamp});
    defer allocator.free(slot_name);
    const pub_name = try std.fmt.allocPrint(allocator, "e2e_stream_insert_pub_{d}", .{timestamp});
    defer allocator.free(pub_name);

    // Create test table with REPLICA IDENTITY FULL
    try test_helpers.createTestTable(conn, allocator, table_name);
    const replica_sql = try test_helpers.formatSqlZ(allocator, "ALTER TABLE {s} REPLICA IDENTITY FULL;", .{table_name});
    defer allocator.free(replica_sql);
    _ = c.PQexec(conn, replica_sql.ptr);

    // Create stream configuration
    const stream_config = try test_helpers.createTestStreamConfig(allocator, table_name, topic_name);
    defer allocator.free(stream_config.name);

    // Create source
    // NOTE: source will be deinit'd by processor.deinit() - no need for defer here
    var source = PostgresSource.init(allocator, slot_name, pub_name);

    // Cleanup: Drop replication slot after test
    defer {
        const drop_slot_sql_tmp = std.fmt.allocPrint(allocator, "SELECT pg_drop_replication_slot('{s}');", .{slot_name}) catch unreachable;
        defer allocator.free(drop_slot_sql_tmp);
        const drop_slot_sql = allocator.dupeZ(u8, drop_slot_sql_tmp) catch unreachable;
        defer allocator.free(drop_slot_sql);
        _ = c.PQexec(conn, drop_slot_sql.ptr);
    }

    // Connect to PostgreSQL
    try source.connect(conn_str, "0/0");

    // Create processor
    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = stream_config;

    var producer = try KafkaProducer.init(allocator, "localhost:9092", null);
    try producer.testConnection();

    var obs = Observability.noop();
    var processor = Processor.init(allocator, source, producer, streams, &obs);
    defer processor.deinit();

    std.debug.print("\n=== E2E INSERT TEST ===\n", .{});

    // Execute: Insert 3 records
    std.debug.print("Step 1: Insert 3 records into {s}\n", .{table_name});
    const insert1 = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Alice', 100);", .{table_name});
    defer allocator.free(insert1);
    const insert2 = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Bob', 200);", .{table_name});
    defer allocator.free(insert2);
    const insert3 = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Carol', 300);", .{table_name});
    defer allocator.free(insert3);

    _ = c.PQexec(conn, insert1.ptr);
    _ = c.PQexec(conn, insert2.ptr);
    _ = c.PQexec(conn, insert3.ptr);
    test_helpers.sleepNs(std.testing.io, 200_000_000); // 200ms

    // Process CDC pipeline
    std.debug.print("Step 2: Process CDC pipeline\n", .{});

    // Use arena allocator for batch processing (matches production usage)
    var batch_arena = std.heap.ArenaAllocator.init(allocator);
    defer batch_arena.deinit();

    try processor.processChangesToKafka(std.testing.io, batch_arena.allocator(), 100);

    // Verify: Read ALL messages from Kafka
    std.debug.print("Step 3: Consume and verify messages from Kafka topic '{s}'\n", .{topic_name});
    const messages = try test_helpers.consumeAllMessages(std.testing.io, allocator, topic_name, 10000);
    defer test_helpers.cleanupJsonMessages(messages, allocator);

    // CRITICAL: Exactly 3 messages (no duplicates, no loss)
    std.debug.print("Step 4: Verify message count (expected: 3, got: {})\n", .{messages.len});
    try testing.expectEqual(@as(usize, 3), messages.len);

    // Verify JSON structure and content for each message
    std.debug.print("Step 5: Verify JSON structure and content\n", .{});
    const expected_names = [_][]const u8{ "Alice", "Bob", "Carol" };
    const expected_values = [_]i64{ 100, 200, 300 };

    for (messages, 0..) |msg, i| {
        std.debug.print("  Message {}: Verifying op, meta, and data fields\n", .{i + 1});

        // Verify operation type
        try test_helpers.assertJsonField(msg, "op", "INSERT");

        // Verify metadata
        try test_helpers.assertJsonField(msg, "meta.resource", table_name);
        try test_helpers.assertJsonField(msg, "meta.schema", "public");
        try test_helpers.assertJsonField(msg, "meta.source", "postgres");
        try test_helpers.assertJsonHasField(msg, "meta.timestamp");

        // Verify data fields exist
        try test_helpers.assertJsonHasField(msg, "data.id");
        try test_helpers.assertJsonHasField(msg, "data.name");
        try test_helpers.assertJsonHasField(msg, "data.value");

        // Verify data values
        try test_helpers.assertJsonField(msg, "data.name", expected_names[i]);

        // INT column is emitted as a real JSON number, not a quoted string
        const data_obj = msg.value.object.get("data").?.object;
        try testing.expectEqual(expected_values[i], data_obj.get("value").?.integer);
    }

    std.debug.print("=== TEST COMPLETED SUCCESSFULLY ===\n", .{});
    std.debug.print("✓ 3 INSERT operations resulted in 3 Kafka messages\n", .{});
    std.debug.print("✓ JSON structure is correct (op, data, meta)\n", .{});
    std.debug.print("✓ All field values match expected data\n", .{});
    std.debug.print("✓ No duplicates, no message loss\n", .{});
    std.debug.print("✓ CDC pipeline works correctly\n", .{});
}

test "E2E: UPDATE operation - full pipeline verification" {
    const allocator = testing.allocator;

    // Setup PostgreSQL connection
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

    // Test configuration with unique names
    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "users_stream_update_{d}", .{timestamp});
    defer allocator.free(table_name);
    const topic_name = try std.fmt.allocPrint(allocator, "topic.stream.update.{d}", .{timestamp});
    defer allocator.free(topic_name);
    const slot_name = try std.fmt.allocPrint(allocator, "e2e_stream_update_slot_{d}", .{timestamp});
    defer allocator.free(slot_name);
    const pub_name = try std.fmt.allocPrint(allocator, "e2e_stream_update_pub_{d}", .{timestamp});
    defer allocator.free(pub_name);

    // Create test table with REPLICA IDENTITY FULL
    try test_helpers.createTestTable(conn, allocator, table_name);
    const replica_sql = try test_helpers.formatSqlZ(allocator, "ALTER TABLE {s} REPLICA IDENTITY FULL;", .{table_name});
    defer allocator.free(replica_sql);
    _ = c.PQexec(conn, replica_sql.ptr);

    // Create stream configuration
    const stream_config = try test_helpers.createTestStreamConfig(allocator, table_name, topic_name);
    defer allocator.free(stream_config.name);

    // Create source
    // NOTE: source will be deinit'd by processor.deinit() - no need for defer here
    var source = PostgresSource.init(allocator, slot_name, pub_name);

    // Cleanup: Drop replication slot after test (using main test connection)
    defer {
        const drop_slot_sql_tmp = std.fmt.allocPrint(allocator, "SELECT pg_drop_replication_slot('{s}');", .{slot_name}) catch unreachable;
        defer allocator.free(drop_slot_sql_tmp);
        const drop_slot_sql = allocator.dupeZ(u8, drop_slot_sql_tmp) catch unreachable;
        defer allocator.free(drop_slot_sql);
        _ = c.PQexec(conn, drop_slot_sql.ptr);
    }

    try source.connect(conn_str, "0/0");

    // Create processor
    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = stream_config;

    var producer = try KafkaProducer.init(allocator, "localhost:9092", null);
    try producer.testConnection();

    var obs = Observability.noop();
    var processor = Processor.init(allocator, source, producer, streams, &obs);
    defer processor.deinit();

    std.debug.print("\n=== E2E UPDATE TEST ===\n", .{});

    // Step 1: Insert initial record
    std.debug.print("Step 1: Insert initial record\n", .{});
    const insert_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Alice', 100);", .{table_name});
    defer allocator.free(insert_sql);
    _ = c.PQexec(conn, insert_sql.ptr);
    test_helpers.sleepNs(std.testing.io, 200_000_000); // 200ms

    // Process initial INSERT
    {
        var batch_arena = std.heap.ArenaAllocator.init(allocator);
        defer batch_arena.deinit();
        try processor.processChangesToKafka(std.testing.io, batch_arena.allocator(), 100);
    }

    // Step 2: Update the record twice
    std.debug.print("Step 2: Update the record twice\n", .{});
    const update1_sql = try test_helpers.formatSqlZ(allocator, "UPDATE {s} SET name = 'Alice Updated', value = 200 WHERE name = 'Alice';", .{table_name});
    defer allocator.free(update1_sql);
    const update2_sql = try test_helpers.formatSqlZ(allocator, "UPDATE {s} SET value = 300 WHERE name = 'Alice Updated';", .{table_name});
    defer allocator.free(update2_sql);
    _ = c.PQexec(conn, update1_sql.ptr);
    _ = c.PQexec(conn, update2_sql.ptr);
    test_helpers.sleepNs(std.testing.io, 200_000_000); // 200ms

    // Process UPDATE operations
    std.debug.print("Step 3: Process UPDATE operations\n", .{});
    {
        var batch_arena = std.heap.ArenaAllocator.init(allocator);
        defer batch_arena.deinit();
        try processor.processChangesToKafka(std.testing.io, batch_arena.allocator(), 100);
    }

    // Verify: Read messages from Kafka (1 INSERT + 2 UPDATEs = 3 total)
    std.debug.print("Step 4: Consume and verify messages from Kafka topic '{s}'\n", .{topic_name});
    const messages = try test_helpers.consumeAllMessages(std.testing.io, allocator, topic_name, 10000);
    defer test_helpers.cleanupJsonMessages(messages, allocator);

    std.debug.print("Step 5: Verify message count (expected: 3, got: {})\n", .{messages.len});
    try testing.expectEqual(@as(usize, 3), messages.len);

    // Verify messages
    std.debug.print("Step 6: Verify messages\n", .{});
    try test_helpers.assertJsonField(messages[0], "op", "INSERT");
    try test_helpers.assertJsonField(messages[0], "data.name", "Alice");

    try test_helpers.assertJsonField(messages[1], "op", "UPDATE");
    try test_helpers.assertJsonField(messages[1], "meta.resource", table_name);
    try test_helpers.assertJsonField(messages[1], "data.name", "Alice Updated");

    const data_obj_1 = messages[1].value.object.get("data").?.object;
    try testing.expectEqual(@as(i64, 200), data_obj_1.get("value").?.integer);

    try test_helpers.assertJsonField(messages[2], "op", "UPDATE");
    try test_helpers.assertJsonField(messages[2], "data.name", "Alice Updated");

    const data_obj_2 = messages[2].value.object.get("data").?.object;
    try testing.expectEqual(@as(i64, 300), data_obj_2.get("value").?.integer);

    std.debug.print("=== TEST COMPLETED SUCCESSFULLY ===\n", .{});
    std.debug.print("✓ 2 UPDATE operations resulted in 2 UPDATE messages\n", .{});
    std.debug.print("✓ CDC pipeline captured all changes\n", .{});
}

test "E2E: DELETE operation - full pipeline verification" {
    const allocator = testing.allocator;

    // Setup PostgreSQL connection
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

    // Test configuration with unique names
    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "users_stream_delete_{d}", .{timestamp});
    defer allocator.free(table_name);
    const topic_name = try std.fmt.allocPrint(allocator, "topic.stream.delete.{d}", .{timestamp});
    defer allocator.free(topic_name);
    const slot_name = try std.fmt.allocPrint(allocator, "e2e_stream_delete_slot_{d}", .{timestamp});
    defer allocator.free(slot_name);
    const pub_name = try std.fmt.allocPrint(allocator, "e2e_stream_delete_pub_{d}", .{timestamp});
    defer allocator.free(pub_name);

    // Create test table with REPLICA IDENTITY FULL
    try test_helpers.createTestTable(conn, allocator, table_name);
    const replica_sql = try test_helpers.formatSqlZ(allocator, "ALTER TABLE {s} REPLICA IDENTITY FULL;", .{table_name});
    defer allocator.free(replica_sql);
    _ = c.PQexec(conn, replica_sql.ptr);

    // Create stream configuration
    const stream_config = try test_helpers.createTestStreamConfig(allocator, table_name, topic_name);
    defer allocator.free(stream_config.name);

    // Create source
    // NOTE: source will be deinit'd by processor.deinit() - no need for defer here
    var source = PostgresSource.init(allocator, slot_name, pub_name);

    // Cleanup: Drop replication slot after test (using main test connection)
    defer {
        const drop_slot_sql_tmp = std.fmt.allocPrint(allocator, "SELECT pg_drop_replication_slot('{s}');", .{slot_name}) catch unreachable;
        defer allocator.free(drop_slot_sql_tmp);
        const drop_slot_sql = allocator.dupeZ(u8, drop_slot_sql_tmp) catch unreachable;
        defer allocator.free(drop_slot_sql);
        _ = c.PQexec(conn, drop_slot_sql.ptr);
    }

    try source.connect(conn_str, "0/0");

    // Create processor
    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = stream_config;

    var producer = try KafkaProducer.init(allocator, "localhost:9092", null);
    try producer.testConnection();

    var obs = Observability.noop();
    var processor = Processor.init(allocator, source, producer, streams, &obs);
    defer processor.deinit();

    std.debug.print("\n=== E2E DELETE TEST ===\n", .{});

    // Step 1: Insert records
    std.debug.print("Step 1: Insert 2 records\n", .{});
    const insert1_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Alice', 100);", .{table_name});
    defer allocator.free(insert1_sql);
    const insert2_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Bob', 200);", .{table_name});
    defer allocator.free(insert2_sql);
    _ = c.PQexec(conn, insert1_sql.ptr);
    _ = c.PQexec(conn, insert2_sql.ptr);
    test_helpers.sleepNs(std.testing.io, 200_000_000); // 200ms

    // Process initial INSERTs
    {
        var batch_arena = std.heap.ArenaAllocator.init(allocator);
        defer batch_arena.deinit();
        try processor.processChangesToKafka(std.testing.io, batch_arena.allocator(), 100);
    }

    // Step 2: Delete the records
    std.debug.print("Step 2: Delete both records\n", .{});
    const delete1_sql = try test_helpers.formatSqlZ(allocator, "DELETE FROM {s} WHERE name = 'Alice';", .{table_name});
    defer allocator.free(delete1_sql);
    const delete2_sql = try test_helpers.formatSqlZ(allocator, "DELETE FROM {s} WHERE name = 'Bob';", .{table_name});
    defer allocator.free(delete2_sql);
    _ = c.PQexec(conn, delete1_sql.ptr);
    _ = c.PQexec(conn, delete2_sql.ptr);
    test_helpers.sleepNs(std.testing.io, 200_000_000); // 200ms

    // Process DELETE operations
    std.debug.print("Step 3: Process DELETE operations\n", .{});
    {
        var batch_arena = std.heap.ArenaAllocator.init(allocator);
        defer batch_arena.deinit();
        try processor.processChangesToKafka(std.testing.io, batch_arena.allocator(), 100);
    }

    // Verify: Read messages from Kafka (2 INSERTs + 2 DELETEs = 4 total)
    std.debug.print("Step 4: Consume and verify messages from Kafka topic '{s}'\n", .{topic_name});
    const messages = try test_helpers.consumeAllMessages(std.testing.io, allocator, topic_name, 10000);
    defer test_helpers.cleanupJsonMessages(messages, allocator);

    std.debug.print("Step 5: Verify message count (expected: 4, got: {})\n", .{messages.len});
    try testing.expectEqual(@as(usize, 4), messages.len);

    // Verify messages (count by operation)
    std.debug.print("Step 6: Verify messages\n", .{});

    var insert_count: usize = 0;
    var delete_count: usize = 0;

    for (messages) |msg| {
        const op_obj = msg.value.object.get("op").?;
        const op = op_obj.string;

        if (std.mem.eql(u8, op, "INSERT")) {
            insert_count += 1;
            try test_helpers.assertJsonField(msg, "meta.resource", table_name);
            try test_helpers.assertJsonField(msg, "meta.schema", "public");
        } else if (std.mem.eql(u8, op, "DELETE")) {
            delete_count += 1;
            try test_helpers.assertJsonField(msg, "meta.resource", table_name);
            try test_helpers.assertJsonField(msg, "meta.schema", "public");
        }
    }

    try testing.expectEqual(@as(usize, 2), insert_count);
    try testing.expectEqual(@as(usize, 2), delete_count);

    std.debug.print("=== TEST COMPLETED SUCCESSFULLY ===\n", .{});
    std.debug.print("✓ 2 DELETE operations resulted in 2 DELETE messages\n", .{});
    std.debug.print("✓ CDC pipeline captured all changes\n", .{});
}

// Read a single text cell from a query, or null if no row / SQL NULL. Caller owns the result.
fn querySingleText(conn: *c.PGconn, allocator: std.mem.Allocator, sql: [:0]const u8) !?[]u8 {
    const res = c.PQexec(conn, sql.ptr);
    defer c.PQclear(res);
    if (c.PQresultStatus(res) != c.PGRES_TUPLES_OK) return error.QueryFailed;
    if (c.PQntuples(res) < 1) return null;
    if (c.PQgetisnull(res, 0, 0) == 1) return null;
    return try allocator.dupe(u8, std.mem.span(c.PQgetvalue(res, 0, 0)));
}

test "E2E: a receive with no new changes still confirms the flushed LSN to the slot" {
    const allocator = testing.allocator;

    const conn_str = try test_helpers.getTestConnectionString(allocator);
    defer allocator.free(conn_str);
    const conn_str_z = try allocator.dupeZ(u8, conn_str);
    defer allocator.free(conn_str_z);
    const conn = c.PQconnectdb(conn_str_z.ptr) orelse return error.ConnectionFailed;
    defer c.PQfinish(conn);
    if (c.PQstatus(conn) != c.CONNECTION_OK) return error.ConnectionFailed;

    const timestamp = test_helpers.nowSeconds(std.testing.io);
    const table_name = try std.fmt.allocPrint(allocator, "idle_commit_{d}", .{timestamp});
    defer allocator.free(table_name);
    const topic_name = try std.fmt.allocPrint(allocator, "topic.idle.commit.{d}", .{timestamp});
    defer allocator.free(topic_name);
    const slot_name = try std.fmt.allocPrint(allocator, "idle_commit_slot_{d}", .{timestamp});
    defer allocator.free(slot_name);
    const pub_name = try std.fmt.allocPrint(allocator, "idle_commit_pub_{d}", .{timestamp});
    defer allocator.free(pub_name);

    try test_helpers.createTestTable(conn, allocator, table_name);
    const replica_sql = try test_helpers.formatSqlZ(allocator, "ALTER TABLE {s} REPLICA IDENTITY FULL;", .{table_name});
    defer allocator.free(replica_sql);
    _ = c.PQexec(conn, replica_sql.ptr);

    const stream_config = try test_helpers.createTestStreamConfig(allocator, table_name, topic_name);
    defer allocator.free(stream_config.name);

    // NOTE: source is moved into the processor, which deinits it (releasing the slot).
    var source = PostgresSource.init(allocator, slot_name, pub_name);
    defer {
        const drop_tmp = std.fmt.allocPrint(allocator, "SELECT pg_drop_replication_slot('{s}');", .{slot_name}) catch unreachable;
        defer allocator.free(drop_tmp);
        const drop = allocator.dupeZ(u8, drop_tmp) catch unreachable;
        defer allocator.free(drop);
        _ = c.PQexec(conn, drop.ptr);
    }
    try source.connect(conn_str, "0/0");

    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = stream_config;

    var producer = try KafkaProducer.init(allocator, "localhost:9092", null);
    try producer.testConnection();

    var obs = Observability.noop();
    var processor = Processor.init(allocator, source, producer, streams, &obs);
    defer processor.deinit();

    // Baseline: the slot's confirmed position right after creation.
    const baseline_sql = try test_helpers.formatSqlZ(allocator, "SELECT confirmed_flush_lsn::text FROM pg_replication_slots WHERE slot_name = '{s}';", .{slot_name});
    defer allocator.free(baseline_sql);
    const baseline = (try querySingleText(conn, allocator, baseline_sql)) orelse try allocator.dupe(u8, "0/0");
    defer allocator.free(baseline);

    // Produce some WAL and receive it, so pending_lsn advances past the baseline.
    const insert = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Alice', 1), ('Bob', 2);", .{table_name});
    defer allocator.free(insert);
    _ = c.PQexec(conn, insert.ptr);
    test_helpers.sleepNs(std.testing.io, 200_000_000);

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try processor.processChangesToKafka(std.testing.io, arena.allocator(), 100);
    }

    // Simulate the flush worker: flush Kafka, then publish how far we flushed.
    try processor.producer.flush(5000);
    processor.flushed_lsn.store(processor.pending_lsn.load(.acquire), .release);

    // Now idle -- no new changes. The next receive must still send the confirmed
    // LSN as standby feedback (receiveBatch sends it before reading), advancing
    // the slot.
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try processor.processChangesToKafka(std.testing.io, arena.allocator(), 100);
    }

    // The slot's confirmed_flush_lsn must have advanced past the baseline.
    const advanced_sql = try test_helpers.formatSqlZ(
        allocator,
        "SELECT (confirmed_flush_lsn > '{s}'::pg_lsn) FROM pg_replication_slots WHERE slot_name = '{s}';",
        .{ baseline, slot_name },
    );
    defer allocator.free(advanced_sql);

    var advanced = false;
    var attempts: usize = 0;
    while (attempts < 25) : (attempts += 1) { // up to ~5s for the walsender to record it
        test_helpers.sleepNs(std.testing.io, 200_000_000);
        if (try querySingleText(conn, allocator, advanced_sql)) |val| {
            defer allocator.free(val);
            if (std.mem.eql(u8, val, "t")) {
                advanced = true;
                break;
            }
        }
    }

    try testing.expect(advanced);
}
