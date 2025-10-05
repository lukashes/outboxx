const std = @import("std");
const wal_reader_module = @import("wal_reader");
const WalReader = wal_reader_module.WalReader;
const WalEvent = wal_reader_module.WalEvent;
const WalReaderError = wal_reader_module.WalReaderError;
const KafkaProducer = @import("kafka_producer").KafkaProducer;
const config_module = @import("config");
const KafkaConfig = config_module.KafkaSink;
const Stream = config_module.Stream;

// New architecture imports
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const postgres_parser = @import("postgres_wal_parser");
const WalParser = postgres_parser.WalParser;
const json_serializer = @import("json_serialization");
const JsonSerializer = json_serializer.JsonSerializer;

// Kafka flush timeout: 30 seconds is a balance between:
// - Allowing enough time for Kafka brokers to acknowledge messages
// - Not blocking CDC processing for too long on Kafka issues
const KAFKA_FLUSH_TIMEOUT_MS: i32 = 30_000;

pub const Processor = struct {
    allocator: std.mem.Allocator,
    wal_reader: *WalReader,
    kafka_producer: ?KafkaProducer,
    kafka_config: KafkaConfig,
    streams: []const Stream,
    wal_parser: WalParser,
    serializer: JsonSerializer,

    last_sent_lsn: ?[]const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, wal_reader: *WalReader, streams: []const Stream, kafka_config: KafkaConfig) Self {
        return Self{
            .allocator = allocator,
            .wal_reader = wal_reader,
            .kafka_producer = null,
            .kafka_config = kafka_config,
            .streams = streams,
            .wal_parser = WalParser.init(allocator),
            .serializer = JsonSerializer.init(),
            .last_sent_lsn = null,
        };
    }

    pub fn shutdown(self: *Self) void {
        std.log.debug("Shutting down processor...", .{});

        self.flushAndCommit() catch |err| {
            std.log.warn("Failed to flush and commit on shutdown: {}", .{err});
        };

        std.log.debug("Shutdown finished", .{});
    }

    pub fn deinit(self: *Self) void {
        if (self.last_sent_lsn) |lsn| {
            self.allocator.free(lsn);
        }
        if (self.kafka_producer) |*producer| {
            producer.deinit();
        }
        // Note: wal_reader is not owned by Processor, so we don't deinit it
        self.wal_parser.deinit();
    }

    pub fn initialize(self: *Self) WalReaderError!void {
        // Note: WalReader is already initialized by caller

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

    pub fn createSlot(self: *Self) WalReaderError!void {
        return self.wal_reader.createSlot();
    }

    pub fn dropSlot(self: *Self) WalReaderError!void {
        return self.wal_reader.dropSlot();
    }

    pub fn flushAndCommit(self: *Self) WalReaderError!void {
        if (self.last_sent_lsn == null) {
            return;
        }

        var kafka_producer = &(self.kafka_producer orelse return WalReaderError.ConnectionFailed);

        std.log.debug("Flushing Kafka messages (timeout: {}ms)...", .{KAFKA_FLUSH_TIMEOUT_MS});
        kafka_producer.flush(KAFKA_FLUSH_TIMEOUT_MS);

        const lsn = self.last_sent_lsn.?;
        std.log.debug("Committing WAL position to LSN: {s}", .{lsn});
        try self.wal_reader.advanceSlot(lsn);

        std.log.debug("Successfully committed LSN: {s}", .{lsn});
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
        // Always peek from current slot position
        var events = try self.wal_reader.peekChanges(limit);
        defer {
            for (events.items) |*event| {
                event.deinit(self.allocator);
            }
            events.deinit(self.allocator);
        }

        // If no events, nothing to do
        if (events.items.len == 0) {
            return;
        }

        var kafka_producer = &(self.kafka_producer orelse return WalReaderError.ConnectionFailed);

        // Process entire batch asynchronously
        for (events.items) |wal_event| {
            // Track LSN for ALL events (including BEGIN/COMMIT)
            // This ensures slot advances even if batch has no parseable events
            const new_lsn = try self.allocator.dupe(u8, wal_event.lsn);
            if (self.last_sent_lsn) |old_lsn| {
                self.allocator.free(old_lsn);
            }
            self.last_sent_lsn = new_lsn;

            // Try to parse WAL event
            // Note: Fast filtering happens in WalReader.peekChanges() for test_decoding
            if (self.wal_parser.parse(wal_event.data, "postgres")) |change_event_opt| {
                if (change_event_opt) |domain_event| {
                    var event = domain_event;
                    defer event.deinit(self.allocator);

                    // Find matching streams for this event
                    var matched_streams = self.matchStreams(event.meta.resource, event.op);
                    defer matched_streams.deinit(self.allocator);

                    if (matched_streams.items.len == 0) {
                        std.log.debug("No matching streams for {s}.{s} ({s})", .{ event.meta.schema, event.meta.resource, event.op });
                        continue;
                    }

                    // Serialize once, send to all matching streams
                    const json_bytes = self.serializer.serialize(event, self.allocator) catch |err| {
                        std.log.warn("Failed to serialize message to JSON: {}", .{err});
                        continue;
                    };
                    defer self.allocator.free(json_bytes);

                    // Send to all matching streams
                    for (matched_streams.items) |stream| {
                        const partition_key_field = stream.sink.routing_key orelse "id";
                        const partition_key = if (event.getPartitionKeyValue(self.allocator, partition_key_field)) |key_opt| blk: {
                            if (key_opt) |key| {
                                break :blk key;
                            } else {
                                break :blk try self.allocator.dupe(u8, event.meta.resource);
                            }
                        } else |_| blk: {
                            break :blk try self.allocator.dupe(u8, event.meta.resource);
                        };
                        defer self.allocator.free(partition_key);

                        const topic_name = stream.sink.destination;

                        kafka_producer.sendMessage(topic_name, partition_key, json_bytes) catch |err| {
                            std.log.warn("Failed to send message to Kafka topic '{s}': {}", .{ topic_name, err });
                            continue;
                        };

                        std.log.debug("Sent {s} message for {s}.{s} to topic '{s}' (partition key: {s})", .{ event.op, event.meta.schema, event.meta.resource, topic_name, partition_key });
                    }
                }
            } else |err| {
                std.log.warn("Skipped WAL event (parse error): {}", .{err});
            }
        }

        // Flush and commit after processing entire batch
        if (self.last_sent_lsn != null) {
            try self.flushAndCommit();
        }
    }

    pub fn startStreaming(self: *Self) !void {
        std.log.info("Starting CDC streaming from PostgreSQL to Kafka", .{});

        while (true) {
            self.processChangesToKafka(100) catch |err| {
                std.log.warn("Error in streaming (will retry): {}", .{err});
                // Continue streaming even if there's an error
            };

            // Sleep between polls
            std.Thread.sleep(1 * std.time.ns_per_s); // 10 seconds
        }
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

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, &wal_reader, streams, kafka_config);
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

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, &wal_reader, streams, kafka_config);
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

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, &wal_reader, streams, kafka_config);
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

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, &wal_reader, streams, kafka_config);
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

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, &wal_reader, streams, kafka_config);
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

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, &wal_reader, streams, kafka_config);
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

    const kafka_config = KafkaSink{ .brokers = &[_][]const u8{"localhost:9092"} };
    var processor = Processor.init(allocator, &wal_reader, streams, kafka_config);
    defer processor.deinit();

    var matched = processor.matchStreams("users", "insert");
    defer matched.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), matched.items.len);
}
