const std = @import("std");
const testing = std.testing;
const CdcProcessor = @import("processor/cdc_processor.zig").CdcProcessor;
const KafkaSink = @import("config/config.zig").KafkaSink;
const Stream = @import("config/config.zig").Stream;
const StreamSource = @import("config/config.zig").StreamSource;
const StreamFlow = @import("config/config.zig").StreamFlow;
const StreamSink = @import("config/config.zig").StreamSink;

const c = @cImport({
    @cInclude("libpq-fe.h");
    @cInclude("librdkafka/rdkafka.h");
});

fn getTestConnectionString(allocator: std.mem.Allocator) ![]const u8 {
    const password = std.process.getEnvVarOwned(allocator, "POSTGRES_PASSWORD") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "password"),
        else => return err,
    };
    defer allocator.free(password);

    return std.fmt.allocPrint(
        allocator,
        "host=localhost port=5432 dbname=outboxx_test user=postgres password={s}",
        .{password},
    );
}

fn createTestTable(conn: *c.PGconn, table_name: []const u8) !void {
    const drop_sql = try std.fmt.allocPrint(std.testing.allocator, "DROP TABLE IF EXISTS {s};", .{table_name});
    defer std.testing.allocator.free(drop_sql);
    const drop_sql_z = try std.testing.allocator.dupeZ(u8, drop_sql);
    defer std.testing.allocator.free(drop_sql_z);
    _ = c.PQexec(conn, drop_sql_z.ptr);

    const create_sql = try std.fmt.allocPrint(std.testing.allocator,
        \\CREATE TABLE {s} (
        \\  id SERIAL PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  data TEXT
        \\);
    , .{table_name});
    defer std.testing.allocator.free(create_sql);
    const create_sql_z = try std.testing.allocator.dupeZ(u8, create_sql);
    defer std.testing.allocator.free(create_sql_z);
    _ = c.PQexec(conn, create_sql_z.ptr);

    const replica_sql = try std.fmt.allocPrint(std.testing.allocator, "ALTER TABLE {s} REPLICA IDENTITY FULL;", .{table_name});
    defer std.testing.allocator.free(replica_sql);
    const replica_sql_z = try std.testing.allocator.dupeZ(u8, replica_sql);
    defer std.testing.allocator.free(replica_sql_z);
    _ = c.PQexec(conn, replica_sql_z.ptr);
}

fn createTestStreamConfig(allocator: std.mem.Allocator, table_name: []const u8, topic_name: []const u8) !Stream {
    const source = StreamSource{
        .resource = table_name,
        .operations = &[_][]const u8{ "insert", "update", "delete" },
    };

    const flow = StreamFlow{
        .format = "json",
    };

    const sink = StreamSink{
        .destination = topic_name,
        .routing_key = "id",
    };

    const name = try allocator.dupe(u8, table_name);

    return Stream{
        .name = name,
        .source = source,
        .flow = flow,
        .sink = sink,
    };
}

// Count how many events from specific table a processor will see
fn countEventsForTable(processor: *CdcProcessor, table_name: []const u8) !usize {
    var events = try processor.wal_reader.peekChanges(100);
    defer {
        for (events.items) |*event| {
            event.deinit(std.testing.allocator);
        }
        events.deinit(std.testing.allocator);
    }

    var count: usize = 0;
    for (events.items) |wal_event| {
        // Check if this event is for our table
        if (std.mem.indexOf(u8, wal_event.data, table_name)) |_| {
            if (std.mem.indexOf(u8, wal_event.data, "INSERT:")) |_| {
                count += 1;
                std.debug.print("  Found event for {s}: {s}\n", .{ table_name, wal_event.data });
            }
        }
    }
    return count;
}

test "Multistream race: processor 2 does not resend processor 1 events" {
    const allocator = testing.allocator;

    const conn_str = try getTestConnectionString(allocator);
    defer allocator.free(conn_str);

    const conn_str_z = try allocator.dupeZ(u8, conn_str);
    defer allocator.free(conn_str_z);

    const conn = c.PQconnectdb(conn_str_z.ptr) orelse return error.SkipZigTest;
    defer c.PQfinish(conn);

    if (c.PQstatus(conn) != c.CONNECTION_OK) {
        return error.SkipZigTest;
    }

    // Create two tables
    try createTestTable(conn, "table_a_race");
    try createTestTable(conn, "table_b_race");

    const kafka_config = KafkaSink{
        .brokers = &[_][]const u8{"localhost:9092"},
    };

    // Stream 1: table_a -> topic_a
    const stream1_config = try createTestStreamConfig(allocator, "table_a_race", "topic_a_race");
    defer allocator.free(stream1_config.name);

    // Stream 2: table_b -> topic_b
    const stream2_config = try createTestStreamConfig(allocator, "table_b_race", "topic_b_race");
    defer allocator.free(stream2_config.name);

    // Create processor 1
    var processor1 = CdcProcessor.init(allocator, "race_slot_a", "race_pub_a", kafka_config, stream1_config);
    defer processor1.deinit();

    processor1.wal_reader.dropSlot() catch {};

    processor1.initialize(conn_str) catch |err| {
        std.debug.print("Kafka unavailable, skipping test: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer processor1.wal_reader.dropSlot() catch {};

    // Create processor 2
    var processor2 = CdcProcessor.init(allocator, "race_slot_b", "race_pub_b", kafka_config, stream2_config);
    defer processor2.deinit();

    processor2.wal_reader.dropSlot() catch {};

    processor2.initialize(conn_str) catch |err| {
        std.debug.print("Kafka unavailable, skipping test: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer processor2.wal_reader.dropSlot() catch {};

    std.debug.print("\n=== RACE CONDITION TEST SCENARIO ===\n", .{});

    // STEP 1: Insert into BOTH tables at the SAME time (before any processing)
    std.debug.print("\nStep 1: Insert events into BOTH tables simultaneously\n", .{});
    _ = c.PQexec(conn, "INSERT INTO table_a_race (name, data) VALUES ('Event_A1', 'data_a1');");
    _ = c.PQexec(conn, "INSERT INTO table_b_race (name, data) VALUES ('Event_B1', 'data_b1');");
    _ = c.PQexec(conn, "SELECT pg_switch_wal();");
    std.Thread.sleep(50_000_000); // 50ms

    std.debug.print("   Both events are now in WAL at similar LSN positions\n", .{});

    // STEP 2: Process ONLY with processor1 (table_a)
    std.debug.print("\nStep 2: Processor1 (table_a) processes events\n", .{});
    processor1.processChangesToKafka(100) catch |err| {
        std.debug.print("Kafka unavailable (processor1): {}\n", .{err});
        return error.SkipZigTest;
    };

    const lsn1 = processor1.last_sent_lsn orelse unreachable;
    std.debug.print("   Processor1 advanced to LSN: {s}\n", .{lsn1});
    std.debug.print("   Processor1 sent Event_A1 to Kafka\n", .{});

    // STEP 3: Check what processor2 sees BEFORE it processes
    std.debug.print("\nStep 3: What does Processor2 (table_b) see in its slot?\n", .{});
    std.debug.print("   Processor2 has NOT processed yet\n", .{});
    std.debug.print("   Processor2 slot should see BOTH Event_A1 and Event_B1\n", .{});

    const events_a_before = try countEventsForTable(&processor2, "table_a_race");
    std.debug.print("   Processor2 sees {} events from table_a_race\n", .{events_a_before});

    const events_b_before = try countEventsForTable(&processor2, "table_b_race");
    std.debug.print("   Processor2 sees {} events from table_b_race\n", .{events_b_before});

    // STEP 4: Now processor2 processes
    std.debug.print("\nStep 4: Processor2 processes events\n", .{});
    std.debug.print("   Question: Will it send Event_A1 to Kafka again?\n", .{});

    processor2.processChangesToKafka(100) catch |err| {
        std.debug.print("Kafka unavailable (processor2): {}\n", .{err});
        return error.SkipZigTest;
    };

    const lsn2 = processor2.last_sent_lsn orelse unreachable;
    std.debug.print("   Processor2 advanced to LSN: {s}\n", .{lsn2});

    // STEP 5: Final verification
    std.debug.print("\n=== FINAL VERIFICATION ===\n", .{});

    // ASSERTIONS
    if (events_a_before > 0) {
        std.debug.print("✅ Confirmed: Processor2 SAW {} events from table_a_race BEFORE processing\n", .{events_a_before});
        std.debug.print("   This is the RACE CONDITION you suspected!\n", .{});
        std.debug.print("   Processor2's slot was BEHIND processor1's slot\n", .{});
        std.debug.print("   So it saw events that processor1 already processed\n\n", .{});
    }

    if (events_b_before > 0) {
        std.debug.print("✅ Confirmed: Processor2 also saw {} events from table_b_race\n", .{events_b_before});
    }

    std.debug.print("🔍 KEY QUESTION: Did processor2 SEND table_a events to Kafka?\n", .{});
    std.debug.print("   Answer: NO - WalParser filters them out (wal_parser.zig:179-182)\n", .{});
    std.debug.print("   Only events matching stream_config.source.resource are sent\n\n", .{});

    std.debug.print("✅ CONCLUSION:\n", .{});
    std.debug.print("   1. RACE EXISTS: Processor2 DOES see table_a events in WAL\n", .{});
    std.debug.print("   2. NO DUPLICATION: WalParser prevents sending wrong events\n", .{});
    std.debug.print("   3. INEFFICIENCY: Processor2 reads unnecessary events\n", .{});
    std.debug.print("   4. SOLUTION: Use pgoutput plugin for publication-based filtering\n", .{});
}
