const std = @import("std");

// PostgreSQL polling source
const postgres_polling = @import("postgres_polling_source");
const PostgresPollingSource = postgres_polling.PostgresPollingSource;
const Batch = postgres_polling.Batch;

// Infrastructure
const KafkaProducer = @import("kafka_producer").KafkaProducer;
const config_module = @import("config");
const KafkaConfig = config_module.KafkaSink;
const Stream = config_module.Stream;

// Domain and serialization
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const json_serializer = @import("json_serialization");
const JsonSerializer = json_serializer.JsonSerializer;

// Legacy - for error type compatibility
const wal_reader_module = @import("wal_reader");
const WalReaderError = wal_reader_module.WalReaderError;

// Kafka flush timeout: 30 seconds is a balance between:
// - Allowing enough time for Kafka brokers to acknowledge messages
// - Not blocking CDC processing for too long on Kafka issues
const KAFKA_FLUSH_TIMEOUT_MS: i32 = 30_000;

pub const Processor = struct {
    allocator: std.mem.Allocator,
    source: PostgresPollingSource,
    kafka_producer: ?KafkaProducer,
    kafka_config: KafkaConfig,
    streams: []const Stream,
    serializer: JsonSerializer,

    events_processed: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source: PostgresPollingSource, streams: []const Stream, kafka_config: KafkaConfig) Self {
        return Self{
            .allocator = allocator,
            .source = source,
            .kafka_producer = null,
            .kafka_config = kafka_config,
            .streams = streams,
            .serializer = JsonSerializer.init(),
            .events_processed = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.kafka_producer) |*producer| {
            producer.deinit();
        }
        self.source.deinit();
    }

    pub fn initialize(self: *Self) WalReaderError!void {
        // Initialize Kafka producer
        const brokers_str = try std.mem.join(self.allocator, ",", self.kafka_config.brokers);
        defer self.allocator.free(brokers_str);

        self.kafka_producer = KafkaProducer.init(self.allocator, brokers_str) catch |err| {
            std.log.warn("Failed to initialize Kafka producer: {}", .{err});
            return WalReaderError.ConnectionFailed;
        };

        // Test Kafka connection at startup (fail-fast if unavailable)
        var producer = &self.kafka_producer.?;
        producer.testConnection() catch |err| {
            std.log.warn("Kafka connection test failed: {}", .{err});
            return WalReaderError.ConnectionFailed;
        };

        std.log.info("Processor initialized successfully", .{});
    }

    // Match streams that should process this event based on table and operation
    fn matchStreams(self: *Self, table_name: []const u8, operation: []const u8) std.ArrayList(Stream) {
        var matched = std.ArrayList(Stream).empty;

        for (self.streams) |stream| {
            // Check if table matches
            if (!std.mem.eql(u8, stream.source.resource, table_name)) {
                continue;
            }

            // Check if operation matches (case-insensitive)
            var operation_matched = false;
            for (stream.source.operations) |op| {
                if (std.ascii.eqlIgnoreCase(op, operation)) {
                    operation_matched = true;
                    break;
                }
            }

            if (operation_matched) {
                matched.append(self.allocator, stream) catch continue;
            }
        }

        return matched;
    }

    pub fn processChangesToKafka(self: *Self, limit: u32) WalReaderError!void {
        // Receive batch of changes from source
        var batch = try self.source.receiveBatch(limit);
        defer batch.deinit();

        // If no events, nothing to do
        if (batch.changes.len == 0) {
            return;
        }

        var kafka_producer = &(self.kafka_producer orelse return WalReaderError.ConnectionFailed);

        std.log.debug("Processing {} changes from batch (LSN: {})", .{ batch.changes.len, batch.last_lsn });

        // Process each change event
        for (batch.changes) |change_event| {
            // Find matching streams for this event
            var matched_streams = self.matchStreams(change_event.meta.resource, change_event.op);
            defer matched_streams.deinit(self.allocator);

            if (matched_streams.items.len == 0) {
                std.log.debug("No matching streams for {s}.{s} ({s})", .{ change_event.meta.schema, change_event.meta.resource, change_event.op });
                continue;
            }

            // Serialize once, send to all matching streams
            const json_bytes = self.serializer.serialize(change_event, self.allocator) catch |err| {
                std.log.warn("Failed to serialize message to JSON: {}", .{err});
                continue;
            };
            defer self.allocator.free(json_bytes);

            // Send to all matching streams
            for (matched_streams.items) |stream| {
                const partition_key_field = stream.sink.routing_key orelse "id";
                const partition_key = if (change_event.getPartitionKeyValue(self.allocator, partition_key_field)) |key_opt| blk: {
                    if (key_opt) |key| {
                        break :blk key;
                    } else {
                        break :blk try self.allocator.dupe(u8, change_event.meta.resource);
                    }
                } else |_| blk: {
                    break :blk try self.allocator.dupe(u8, change_event.meta.resource);
                };
                defer self.allocator.free(partition_key);

                const topic_name = stream.sink.destination;

                kafka_producer.sendMessage(topic_name, partition_key, json_bytes) catch |err| {
                    std.log.warn("Failed to send message to Kafka topic '{s}': {}", .{ topic_name, err });
                    continue;
                };

                // Increment events counter
                self.events_processed += 1;

                // Log progress every 10000 events
                if (self.events_processed % 10000 == 0) {
                    std.log.info("Processed {} CDC events", .{self.events_processed});
                }

                std.log.debug("Sent {s} message for {s}.{s} to topic '{s}' (partition key: {s})", .{ change_event.op, change_event.meta.schema, change_event.meta.resource, topic_name, partition_key });
            }
        }

        // CRITICAL: Kafka flush BEFORE LSN feedback (no data loss guarantee)
        kafka_producer.flush(KAFKA_FLUSH_TIMEOUT_MS);

        // Confirm LSN to PostgreSQL ONLY after Kafka flush succeeds
        try self.source.sendFeedback(batch.last_lsn);

        std.log.debug("Successfully committed LSN: {}", .{batch.last_lsn});
    }

    pub fn startStreaming(self: *Self, stop_signal: *std.atomic.Value(bool)) !void {
        while (!stop_signal.load(.monotonic)) {
            self.processChangesToKafka(100000) catch |err| {
                std.log.warn("Error in streaming (will retry): {}", .{err});
                // Continue streaming even if there's an error
            };

            // Sleep between polls
            std.Thread.sleep(1 * std.time.ns_per_s); // 1 second between polls
        }

        std.log.info("Streaming stopped gracefully", .{});
    }
};

// Unit tests for matchStreams routing logic
const testing = std.testing;
const KafkaSink = config_module.KafkaSink;

fn createTestStream(allocator: std.mem.Allocator, resource: []const u8, operations: []const []const u8, destination: []const u8) !Stream {
    const stream = Stream{
        .name = try allocator.dupe(u8, "test_stream"),
        .source = .{
            .resource = resource,
            .operations = operations,
        },
        .flow = .{
            .format = "json",
        },
        .sink = .{
            .destination = destination,
            .routing_key = "id",
        },
    };
    return stream;
}

test "matchStreams: exact table and operation match" {
    const allocator = testing.allocator;

    const operations = [_][]const u8{"insert"};
    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = try createTestStream(allocator, "users", &operations, "topic.users");
    defer allocator.free(streams[0].name);

    var wal_reader = @import("wal_reader").WalReader.init(allocator, "test_slot", "test_pub", &[_][]const u8{});
    defer wal_reader.deinit();

    var source = PostgresPollingSource.init(allocator, &wal_reader);
    defer source.deinit();

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    var matched = processor.matchStreams("users", "insert");
    defer matched.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), matched.items.len);
    try testing.expectEqualStrings("users", matched.items[0].source.resource);
}

test "matchStreams: case-insensitive operation matching" {
    const allocator = testing.allocator;

    const operations = [_][]const u8{"insert"};
    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = try createTestStream(allocator, "users", &operations, "topic.users");
    defer allocator.free(streams[0].name);

    var wal_reader = @import("wal_reader").WalReader.init(allocator, "test_slot", "test_pub", &[_][]const u8{});
    defer wal_reader.deinit();

    var source = PostgresPollingSource.init(allocator, &wal_reader);
    defer source.deinit();

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    // Test different cases: INSERT, Insert, insert
    var matched_upper = processor.matchStreams("users", "INSERT");
    defer matched_upper.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), matched_upper.items.len);

    var matched_mixed = processor.matchStreams("users", "Insert");
    defer matched_mixed.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), matched_mixed.items.len);

    var matched_lower = processor.matchStreams("users", "insert");
    defer matched_lower.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), matched_lower.items.len);
}

test "matchStreams: no match when table differs" {
    const allocator = testing.allocator;

    const operations = [_][]const u8{"insert"};
    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = try createTestStream(allocator, "users", &operations, "topic.users");
    defer allocator.free(streams[0].name);

    var wal_reader = @import("wal_reader").WalReader.init(allocator, "test_slot", "test_pub", &[_][]const u8{});
    defer wal_reader.deinit();

    var source = PostgresPollingSource.init(allocator, &wal_reader);
    defer source.deinit();

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    var matched = processor.matchStreams("orders", "insert");
    defer matched.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), matched.items.len);
}

test "matchStreams: no match when operation not in list" {
    const allocator = testing.allocator;

    const operations = [_][]const u8{ "insert", "update" };
    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = try createTestStream(allocator, "users", &operations, "topic.users");
    defer allocator.free(streams[0].name);

    var wal_reader = @import("wal_reader").WalReader.init(allocator, "test_slot", "test_pub", &[_][]const u8{});
    defer wal_reader.deinit();

    var source = PostgresPollingSource.init(allocator, &wal_reader);
    defer source.deinit();

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    var matched = processor.matchStreams("users", "delete");
    defer matched.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), matched.items.len);
}

test "matchStreams: multiple streams match same event" {
    const allocator = testing.allocator;

    const ops1 = [_][]const u8{"insert"};
    const ops2 = [_][]const u8{ "insert", "update" };

    const streams = try allocator.alloc(Stream, 2);
    defer allocator.free(streams);
    streams[0] = try createTestStream(allocator, "users", &ops1, "topic.users.inserts");
    defer allocator.free(streams[0].name);
    streams[1] = try createTestStream(allocator, "users", &ops2, "topic.users.all");
    defer allocator.free(streams[1].name);

    var wal_reader = @import("wal_reader").WalReader.init(allocator, "test_slot", "test_pub", &[_][]const u8{});
    defer wal_reader.deinit();

    var source = PostgresPollingSource.init(allocator, &wal_reader);
    defer source.deinit();

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    var matched = processor.matchStreams("users", "insert");
    defer matched.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), matched.items.len);
    try testing.expectEqualStrings("topic.users.inserts", matched.items[0].sink.destination);
    try testing.expectEqualStrings("topic.users.all", matched.items[1].sink.destination);
}

test "matchStreams: multiple operations for same table" {
    const allocator = testing.allocator;

    const operations = [_][]const u8{ "insert", "update", "delete" };
    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = try createTestStream(allocator, "orders", &operations, "topic.orders");
    defer allocator.free(streams[0].name);

    var wal_reader = @import("wal_reader").WalReader.init(allocator, "test_slot", "test_pub", &[_][]const u8{});
    defer wal_reader.deinit();

    var source = PostgresPollingSource.init(allocator, &wal_reader);
    defer source.deinit();

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    // All operations should match
    var matched_insert = processor.matchStreams("orders", "INSERT");
    defer matched_insert.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), matched_insert.items.len);

    var matched_update = processor.matchStreams("orders", "UPDATE");
    defer matched_update.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), matched_update.items.len);

    var matched_delete = processor.matchStreams("orders", "DELETE");
    defer matched_delete.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), matched_delete.items.len);
}

test "matchStreams: empty streams list returns no matches" {
    const allocator = testing.allocator;

    const streams = try allocator.alloc(Stream, 0);
    defer allocator.free(streams);

    var wal_reader = @import("wal_reader").WalReader.init(allocator, "test_slot", "test_pub", &[_][]const u8{});
    defer wal_reader.deinit();

    var source = PostgresPollingSource.init(allocator, &wal_reader);
    defer source.deinit();

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    var matched = processor.matchStreams("users", "insert");
    defer matched.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), matched.items.len);
}
