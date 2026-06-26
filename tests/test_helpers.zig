const std = @import("std");
const config_module = @import("config");
const Stream = config_module.Stream;
const StreamSource = config_module.StreamSource;
const StreamFlow = config_module.StreamFlow;
const StreamSink = config_module.StreamSink;

// Combined libpq + librdkafka bindings (build-system translate-c), re-exported
// so E2E tests use the same C types.
pub const c = @import("c");

// --- Time / sleep / env helpers ---
// Zig 0.16 moved time and sleep behind the Io interface and removed the global
// env accessor. Test modules link libc, so use libc primitives directly here.

/// Wall-clock milliseconds since the Unix epoch.
pub fn nowMillis() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, @intCast(tv.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tv.usec)), 1000);
}

/// Wall-clock seconds since the Unix epoch.
pub fn nowSeconds() i64 {
    return @divTrunc(nowMillis(), 1000);
}

/// Wall-clock microseconds since the Unix epoch.
pub fn nowMicros() i64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, @intCast(tv.sec)) * 1_000_000 + @as(i64, @intCast(tv.usec));
}

/// Sleep for the given number of nanoseconds.
pub fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&req, null);
}

/// Helper to format SQL with null terminator for C APIs
pub fn formatSqlZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const sql = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(sql);
    const sql_z = try allocator.dupeZ(u8, sql);
    allocator.free(sql);
    return sql_z;
}

/// Get PostgreSQL connection string for tests
/// Uses POSTGRES_PASSWORD env var or defaults to "password"
pub fn getTestConnectionString(allocator: std.mem.Allocator) ![]const u8 {
    // std.process.getEnvVarOwned was removed in Zig 0.16; use libc getenv.
    const password: []const u8 = if (std.c.getenv("POSTGRES_PASSWORD")) |p|
        std.mem.span(p)
    else
        "password";

    return std.fmt.allocPrint(
        allocator,
        "host=localhost port=5432 dbname=outboxx_test user=postgres password={s}",
        .{password},
    );
}

/// Create a test table with REPLICA IDENTITY FULL
/// Schema: id SERIAL PRIMARY KEY, name TEXT NOT NULL, value INT
pub fn createTestTable(conn: *c.PGconn, allocator: std.mem.Allocator, table_name: []const u8) !void {
    // Drop if exists
    const drop_sql = try std.fmt.allocPrint(allocator, "DROP TABLE IF EXISTS {s};", .{table_name});
    defer allocator.free(drop_sql);
    const drop_sql_z = try allocator.dupeZ(u8, drop_sql);
    defer allocator.free(drop_sql_z);
    _ = c.PQexec(conn, drop_sql_z.ptr);

    // Create table
    const create_sql = try std.fmt.allocPrint(allocator,
        \\CREATE TABLE {s} (
        \\  id SERIAL PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  value INT
        \\);
    , .{table_name});
    defer allocator.free(create_sql);
    const create_sql_z = try allocator.dupeZ(u8, create_sql);
    defer allocator.free(create_sql_z);
    _ = c.PQexec(conn, create_sql_z.ptr);

    // Set REPLICA IDENTITY FULL
    const replica_sql = try std.fmt.allocPrint(allocator, "ALTER TABLE {s} REPLICA IDENTITY FULL;", .{table_name});
    defer allocator.free(replica_sql);
    const replica_sql_z = try allocator.dupeZ(u8, replica_sql);
    defer allocator.free(replica_sql_z);
    _ = c.PQexec(conn, replica_sql_z.ptr);
}

/// Create test stream configuration
pub fn createTestStreamConfig(allocator: std.mem.Allocator, table_name: []const u8, topic_name: []const u8) !Stream {
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

/// Consume ALL messages from Kafka topic from beginning
/// Returns array of parsed JSON messages
/// Waits up to timeout_ms for messages to arrive
pub fn consumeAllMessages(
    allocator: std.mem.Allocator,
    topic: []const u8,
    timeout_ms: i32,
) ![]std.json.Parsed(std.json.Value) {
    var messages: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
    errdefer {
        for (messages.items) |msg| msg.deinit();
        messages.deinit(allocator);
    }

    var errstr: [512]u8 = undefined;

    // Create consumer with unique group_id (to read from beginning)
    const group_id = try std.fmt.allocPrint(allocator, "test-group-{d}", .{nowSeconds()});
    defer allocator.free(group_id);

    const conf = c.rd_kafka_conf_new();
    if (conf == null) return error.KafkaConfigFailed;

    _ = c.rd_kafka_conf_set(conf, "bootstrap.servers", "localhost:9092", &errstr, errstr.len);

    const group_id_z = try allocator.dupeZ(u8, group_id);
    defer allocator.free(group_id_z);
    _ = c.rd_kafka_conf_set(conf, "group.id", group_id_z.ptr, &errstr, errstr.len);
    _ = c.rd_kafka_conf_set(conf, "auto.offset.reset", "earliest", &errstr, errstr.len);

    const consumer = c.rd_kafka_new(c.RD_KAFKA_CONSUMER, conf, &errstr, errstr.len);
    if (consumer == null) {
        c.rd_kafka_conf_destroy(conf);
        return error.KafkaConsumerFailed;
    }
    defer {
        _ = c.rd_kafka_consumer_close(consumer);
        c.rd_kafka_destroy(consumer);
    }

    // Subscribe to topic
    const topic_list = c.rd_kafka_topic_partition_list_new(1);
    if (topic_list == null) return error.KafkaTopicListFailed;
    defer c.rd_kafka_topic_partition_list_destroy(topic_list);

    const topic_z = try allocator.dupeZ(u8, topic);
    defer allocator.free(topic_z);
    _ = c.rd_kafka_topic_partition_list_add(topic_list, topic_z.ptr, c.RD_KAFKA_PARTITION_UA);

    if (c.rd_kafka_subscribe(consumer, topic_list) != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
        return error.KafkaSubscribeFailed;
    }

    // Poll messages until timeout
    // Give consumer time to subscribe and rebalance
    sleepNs(2_000_000_000); // 2 seconds for consumer to join and get assignments

    const start_time = nowMillis();
    var last_message_time = start_time;

    while (true) {
        const elapsed = nowMillis() - start_time;
        if (elapsed >= timeout_ms) break;

        const message = c.rd_kafka_consumer_poll(consumer, 500);

        if (message != null and message.*.err == c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            const payload_slice = @as([*]const u8, @ptrCast(message.*.payload))[0..message.*.len];
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_slice, .{}) catch |err| {
                c.rd_kafka_message_destroy(message);
                return err;
            };
            try messages.append(allocator, parsed);

            last_message_time = nowMillis();
            c.rd_kafka_message_destroy(message);
        } else {
            if (message != null) c.rd_kafka_message_destroy(message);

            // Stop if no messages for 2 seconds after we got at least one
            if (messages.items.len > 0 and (nowMillis() - last_message_time) > 2000) {
                break;
            }
        }
    }

    return messages.toOwnedSlice(allocator);
}

/// Helper to assert JSON field value at given path
/// Path format: "meta.resource" or "data.name"
pub fn assertJsonField(
    parsed: std.json.Parsed(std.json.Value),
    path: []const u8,
    expected: []const u8,
) !void {
    var current = parsed.value;
    var iter = std.mem.splitScalar(u8, path, '.');

    while (iter.next()) |segment| {
        switch (current) {
            .object => |obj| {
                current = obj.get(segment) orelse {
                    std.debug.print("Field not found: {s}\n", .{path});
                    return error.FieldNotFound;
                };
            },
            else => {
                std.debug.print("Expected object at {s}\n", .{path});
                return error.NotAnObject;
            },
        }
    }

    const actual = switch (current) {
        .string => |s| s,
        else => {
            std.debug.print("Expected string at {s}\n", .{path});
            return error.NotAString;
        },
    };

    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("Expected {s}={s}, got {s}\n", .{ path, expected, actual });
        return error.UnexpectedFieldValue;
    }
}

/// Helper to verify JSON field exists at given path
pub fn assertJsonHasField(
    parsed: std.json.Parsed(std.json.Value),
    path: []const u8,
) !void {
    var current = parsed.value;
    var iter = std.mem.splitScalar(u8, path, '.');

    while (iter.next()) |segment| {
        switch (current) {
            .object => |obj| {
                current = obj.get(segment) orelse {
                    std.debug.print("Field not found: {s}\n", .{path});
                    return error.FieldNotFound;
                };
            },
            else => {
                std.debug.print("Expected object at {s}\n", .{path});
                return error.NotAnObject;
            },
        }
    }
}

/// Cleanup array of JSON messages
pub fn cleanupJsonMessages(messages: []std.json.Parsed(std.json.Value), allocator: std.mem.Allocator) void {
    for (messages) |msg| {
        msg.deinit();
    }
    allocator.free(messages);
}
