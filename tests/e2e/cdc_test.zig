const std = @import("std");
const testing = std.testing;
const test_helpers = @import("test_helpers");

const Processor = @import("cdc_processor").Processor;
const PostgresSource = @import("postgres_source").PostgresSource;
const KafkaSink = @import("config").KafkaSink;
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
pub const std_options = struct {
    pub const log_level = .debug;
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
    const timestamp = std.time.timestamp();
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

    // Kafka configuration
    const kafka_config = KafkaSink{
        .brokers = &[_][]const u8{"localhost:9092"},
    };

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

    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    try processor.initialize();

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
    std.Thread.sleep(200_000_000); // 200ms

    // Process CDC pipeline
    std.debug.print("Step 2: Process CDC pipeline\n", .{});
    try processor.processChangesToKafka(100);

    // Verify: Read ALL messages from Kafka
    std.debug.print("Step 3: Consume and verify messages from Kafka topic '{s}'\n", .{topic_name});
    const messages = try test_helpers.consumeAllMessages(allocator, topic_name, 10000);
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

        // Note: pgoutput sends values as strings, need to parse
        const data_obj = msg.value.object.get("data").?.object;
        const value_str = data_obj.get("value").?.string;
        const value = try std.fmt.parseInt(i64, value_str, 10);
        try testing.expectEqual(expected_values[i], value);
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
    const timestamp = std.time.timestamp();
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

    // Kafka configuration
    const kafka_config = KafkaSink{
        .brokers = &[_][]const u8{"localhost:9092"},
    };

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

    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    try processor.initialize();

    std.debug.print("\n=== E2E UPDATE TEST ===\n", .{});

    // Step 1: Insert initial record
    std.debug.print("Step 1: Insert initial record\n", .{});
    const insert_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Alice', 100);", .{table_name});
    defer allocator.free(insert_sql);
    _ = c.PQexec(conn, insert_sql.ptr);
    std.Thread.sleep(200_000_000); // 200ms

    // Process initial INSERT
    try processor.processChangesToKafka(100);

    // Step 2: Update the record twice
    std.debug.print("Step 2: Update the record twice\n", .{});
    const update1_sql = try test_helpers.formatSqlZ(allocator, "UPDATE {s} SET name = 'Alice Updated', value = 200 WHERE name = 'Alice';", .{table_name});
    defer allocator.free(update1_sql);
    const update2_sql = try test_helpers.formatSqlZ(allocator, "UPDATE {s} SET value = 300 WHERE name = 'Alice Updated';", .{table_name});
    defer allocator.free(update2_sql);
    _ = c.PQexec(conn, update1_sql.ptr);
    _ = c.PQexec(conn, update2_sql.ptr);
    std.Thread.sleep(200_000_000); // 200ms

    // Process UPDATE operations
    std.debug.print("Step 3: Process UPDATE operations\n", .{});
    try processor.processChangesToKafka(100);

    // Verify: Read messages from Kafka (1 INSERT + 2 UPDATEs = 3 total)
    std.debug.print("Step 4: Consume and verify messages from Kafka topic '{s}'\n", .{topic_name});
    const messages = try test_helpers.consumeAllMessages(allocator, topic_name, 10000);
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

    // Note: pgoutput sends values as strings
    const data_obj_1 = messages[1].value.object.get("data").?.object;
    const value_str_1 = data_obj_1.get("value").?.string;
    const value_1 = try std.fmt.parseInt(i64, value_str_1, 10);
    try testing.expectEqual(@as(i64, 200), value_1);

    try test_helpers.assertJsonField(messages[2], "op", "UPDATE");
    try test_helpers.assertJsonField(messages[2], "data.name", "Alice Updated");

    const data_obj_2 = messages[2].value.object.get("data").?.object;
    const value_str_2 = data_obj_2.get("value").?.string;
    const value_2 = try std.fmt.parseInt(i64, value_str_2, 10);
    try testing.expectEqual(@as(i64, 300), value_2);

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
    const timestamp = std.time.timestamp();
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

    // Kafka configuration
    const kafka_config = KafkaSink{
        .brokers = &[_][]const u8{"localhost:9092"},
    };

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

    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    try processor.initialize();

    std.debug.print("\n=== E2E DELETE TEST ===\n", .{});

    // Step 1: Insert records
    std.debug.print("Step 1: Insert 2 records\n", .{});
    const insert1_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Alice', 100);", .{table_name});
    defer allocator.free(insert1_sql);
    const insert2_sql = try test_helpers.formatSqlZ(allocator, "INSERT INTO {s} (name, value) VALUES ('Bob', 200);", .{table_name});
    defer allocator.free(insert2_sql);
    _ = c.PQexec(conn, insert1_sql.ptr);
    _ = c.PQexec(conn, insert2_sql.ptr);
    std.Thread.sleep(200_000_000); // 200ms

    // Process initial INSERTs
    try processor.processChangesToKafka(100);

    // Step 2: Delete the records
    std.debug.print("Step 2: Delete both records\n", .{});
    const delete1_sql = try test_helpers.formatSqlZ(allocator, "DELETE FROM {s} WHERE name = 'Alice';", .{table_name});
    defer allocator.free(delete1_sql);
    const delete2_sql = try test_helpers.formatSqlZ(allocator, "DELETE FROM {s} WHERE name = 'Bob';", .{table_name});
    defer allocator.free(delete2_sql);
    _ = c.PQexec(conn, delete1_sql.ptr);
    _ = c.PQexec(conn, delete2_sql.ptr);
    std.Thread.sleep(200_000_000); // 200ms

    // Process DELETE operations
    std.debug.print("Step 3: Process DELETE operations\n", .{});
    try processor.processChangesToKafka(100);

    // Verify: Read messages from Kafka (2 INSERTs + 2 DELETEs = 4 total)
    std.debug.print("Step 4: Consume and verify messages from Kafka topic '{s}'\n", .{topic_name});
    const messages = try test_helpers.consumeAllMessages(allocator, topic_name, 10000);
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
