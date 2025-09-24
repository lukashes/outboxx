const std = @import("std");
const WalReader = @import("reader.zig").WalReader;
const WalEvent = @import("reader.zig").WalEvent;
const WalReaderError = @import("reader.zig").WalReaderError;
const KafkaProducer = @import("../kafka/producer.zig").KafkaProducer;
const MessageProcessor = @import("../message_processor.zig").MessageProcessor;

pub const KafkaWalReader = struct {
    allocator: std.mem.Allocator,
    wal_reader: WalReader,
    kafka_producer: ?KafkaProducer,
    message_processor: MessageProcessor,
    brokers: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, slot_name: []const u8, brokers: []const u8) Self {
        return Self{
            .allocator = allocator,
            .wal_reader = WalReader.init(allocator, slot_name),
            .kafka_producer = null,
            .message_processor = MessageProcessor.init(allocator),
            .brokers = brokers,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.kafka_producer) |*producer| {
            producer.deinit();
        }
        self.wal_reader.deinit();
        self.message_processor.deinit();
    }

    pub fn connect(self: *Self, connection_string: []const u8) WalReaderError!void {
        // Connect WAL reader
        try self.wal_reader.connect(connection_string);

        // Initialize Kafka producer
        self.kafka_producer = KafkaProducer.init(self.allocator, self.brokers) catch |err| {
            std.log.err("Failed to initialize Kafka producer: {}", .{err});
            return WalReaderError.ConnectionFailed;
        };

        std.log.info("Connected to PostgreSQL and Kafka successfully", .{});
    }

    pub fn createSlot(self: *Self) WalReaderError!void {
        return self.wal_reader.createSlot();
    }

    pub fn dropSlot(self: *Self) WalReaderError!void {
        return self.wal_reader.dropSlot();
    }

    pub fn streamChangesToKafka(self: *Self, limit: u32) WalReaderError!void {
        // Read WAL changes
        var events = try self.wal_reader.readChanges(limit);
        defer {
            for (events.items) |*event| {
                event.deinit(self.allocator);
            }
            events.deinit(self.allocator);
        }

        var kafka_producer = &(self.kafka_producer orelse return WalReaderError.ConnectionFailed);

        std.log.info("Processing {} WAL events", .{events.items.len});

        for (events.items) |event| {
            // Parse WAL event into structured message
            if (self.message_processor.parseWalMessage(event.data)) |message_opt| {
                if (message_opt) |message| {
                    defer {
                        self.allocator.free(message.schema_name);
                        self.allocator.free(message.table_name);
                        self.allocator.free(message.data);
                        if (message.old_data) |old| {
                            self.allocator.free(old);
                        }
                    }

                    // Convert to JSON
                    const json_message = message.toJson(self.allocator) catch |err| {
                        std.log.err("Failed to serialize message to JSON: {}", .{err});
                        continue;
                    };
                    defer self.allocator.free(json_message);

                    // Get topic name
                    const topic_name = message.getTopicName(self.allocator) catch |err| {
                        std.log.err("Failed to generate topic name: {}", .{err});
                        continue;
                    };
                    defer self.allocator.free(topic_name);

                    // Get partition key
                    const partition_key = message.getPartitionKey(self.allocator) catch |err| {
                        std.log.err("Failed to generate partition key: {}", .{err});
                        continue;
                    };
                    defer self.allocator.free(partition_key);

                    // Send to Kafka
                    kafka_producer.sendMessage(topic_name, partition_key, json_message) catch |err| {
                        std.log.err("Failed to send message to Kafka: {}", .{err});
                        continue;
                    };

                    std.log.info("Sent {s} message for {s}.{s}", .{ @tagName(message.operation), message.schema_name, message.table_name });
                }
            } else |err| {
                std.log.err("Failed to parse WAL message: {}", .{err});
                continue;
            }
        }

        // Flush Kafka producer to ensure messages are sent
        kafka_producer.flush(5000); // 5 second timeout
        std.log.info("Flushed messages to Kafka", .{});
    }

    pub fn startStreaming(self: *Self, poll_interval_ms: u64) !void {
        std.log.info("Starting CDC streaming from PostgreSQL to Kafka", .{});

        while (true) {
            self.streamChangesToKafka(100) catch |err| {
                std.log.err("Error in streaming: {}", .{err});
                // Continue streaming even if there's an error
            };

            // Sleep between polls
            std.time.sleep(poll_interval_ms * std.time.ns_per_ms);
        }
    }
};

// Integration test
test "KafkaWalReader basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // This is a structure test - real integration tests will be in separate file
    var reader = KafkaWalReader.init(allocator, "test_slot", "localhost:9092");
    defer reader.deinit();

    // Test that the structure is properly initialized
    try testing.expectEqualStrings("localhost:9092", reader.brokers);
    try testing.expect(reader.kafka_producer == null); // Not connected yet
}